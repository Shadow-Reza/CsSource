// cg-agent is the Chogan auth sidecar for the CS:Source servers (MISSION 6.3).
//
// It listens on 127.0.0.1:8480 and is the only process that talks to the
// Chogan API. It owns retries, the cache, the write queue, the circuit breaker
// and /health. Modes: stub (accept anything), local (own MariaDB tables),
// remote (https://api.chogan.games). See README.md for the HTTP contract.
//
// Layout:
//
//	main.go          flags, logger, wiring, lifecycle (signals, graceful stop)
//	server.go        HTTP handlers (/health, /v1/redeem, /v1/event, /v1/tickets, /v1/cache)
//	service.go       mode-independent redeem logic (cache -> backend -> cache fallback)
//	backend.go       backend/eventSink interfaces, stub backend, log sink
//	store_local.go   "local" mode: MariaDB tickets/accounts/cg_events, DB monitor
//	remote.go        "remote" mode: HTTPS client, retry, breaker accounting
//	breaker.go       circuit breaker
//	cache.go         TTL cache (ticket hash and authid+ip keys)
//	queue.go         bounded async write queue for events
//	sqltransport.go  cg_auth_requests poller (probe-2 fallback transport)
//	ticket.go        hashing, ticket generation, phone masking
//	config.go        config struct, validation, tiny TOML-subset parser
//	types.go         wire types and reason/source constants
package main

import (
	"context"
	"database/sql"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

// version is set at build time: -ldflags "-X main.version=..."
var version = "dev"

func main() {
	cfgPath := flag.String("config", "/etc/cg-agent/config.toml", "path to the config file")
	check := flag.Bool("check", false, "validate the config file and exit")
	showVersion := flag.Bool("version", false, "print version and exit")
	flag.Parse()

	if *showVersion {
		fmt.Println("cg-agent", version)
		return
	}

	cfg, warnings, err := loadConfig(*cfgPath)
	logger := newLogger(cfg.LogLevel)
	if err != nil {
		logger.Error("config error", "path", *cfgPath, "err", err.Error())
		os.Exit(2)
	}
	for _, w := range warnings {
		logger.Warn("config", "warning", w)
	}
	if *check {
		logger.Info("config ok", "path", *cfgPath, "mode", cfg.Mode, "listen", cfg.Listen, "sql_transport", cfg.SQLTransport)
		return
	}
	if err := run(cfg, logger); err != nil {
		logger.Error("fatal", "err", err.Error())
		os.Exit(1)
	}
}

// newLogger returns a JSON logger on stdout (journald captures it; use
// `journalctl -u cg-agent -o cat | jq` to read it).
func newLogger(level string) *slog.Logger {
	var lvl slog.Level
	switch strings.ToLower(strings.TrimSpace(level)) {
	case "debug":
		lvl = slog.LevelDebug
	case "warn", "warning":
		lvl = slog.LevelWarn
	case "error":
		lvl = slog.LevelError
	default:
		lvl = slog.LevelInfo
	}
	h := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: lvl})
	return slog.New(h).With("app", "cg-agent")
}

// app wires the components together and serves the HTTP API (server.go).
type app struct {
	cfg           Config
	log           *slog.Logger
	svc           *Service
	cache         *Cache
	breaker       *Breaker      // remote mode only
	queue         *Queue        // always
	local         *localStore   // set when a DB DSN is configured
	dbmon         *dbMonitor    // set when a DB DSN is configured
	sqlt          *sqlTransport // set when sql_transport = true
	started       time.Time
	redeemTimeout time.Duration
}

func run(cfg Config, log *slog.Logger) error {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	a := &app{cfg: cfg, log: log, started: time.Now()}
	a.cache = NewCache(cfg.CacheTTL, cfg.CacheMax)

	// Worst case for one redeem in remote mode: every attempt times out.
	// The plugin's own HTTP timeout should be a bit above this.
	a.redeemTimeout = 3 * time.Second
	if cfg.Mode == "remote" {
		a.redeemTimeout = time.Duration(cfg.APIRetries+1)*cfg.APITimeout + 500*time.Millisecond
	}

	var db *sql.DB
	if cfg.DBDSN != "" {
		var err error
		db, err = openDB(cfg)
		if err != nil {
			return err
		}
		defer db.Close()
		a.local = &localStore{db: db, log: log}
		a.dbmon = newDBMonitor(db)
		pctx, cancel := context.WithTimeout(ctx, 5*time.Second)
		if err := db.PingContext(pctx); err != nil {
			log.Warn("database not reachable at startup; will keep retrying in the background", "err", err.Error())
		} else {
			log.Info("database connected")
		}
		cancel()
		go a.dbmon.Run(ctx, 10*time.Second)
	}

	var be backend
	var sink eventSink
	switch cfg.Mode {
	case "stub":
		be = stubBackend{}
		sink = logSink{log: log}
	case "local":
		if a.local == nil {
			return errors.New("mode = local requires [db] dsn")
		}
		be = a.local
		sink = a.local
	case "remote":
		a.breaker = NewBreaker(cfg.BreakerFailures, cfg.BreakerWindow, cfg.BreakerProbe)
		rb := newRemoteBackend(cfg, a.breaker, log)
		be = rb
		sink = rb
	default:
		return fmt.Errorf("unknown mode %q", cfg.Mode)
	}
	a.svc = NewService(be, a.cache, log)

	a.queue = NewQueue(cfg.QueueSize, cfg.QueueWorkers, cfg.QueueMaxAttempts, cfg.QueueRetryBase, cfg.QueueRetryMax, sink, log)
	a.queue.Start()

	if a.local != nil {
		// purge old tickets (local mode) / resolved auth requests (sql transport)
		go a.local.Housekeep(ctx, time.Hour, cfg.Mode == "local", cfg.SQLTransport)
	}
	if cfg.SQLTransport {
		if db == nil {
			return errors.New("sql_transport = true requires [db] dsn")
		}
		a.sqlt = newSQLTransport(db, a.svc, log, cfg.SQLPoll, cfg.SQLBatch, a.redeemTimeout)
		go a.sqlt.Run(ctx)
	}
	go a.cacheSweeper(ctx)

	srv := &http.Server{
		Addr:              cfg.Listen,
		Handler:           a.routes(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      20 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    64 << 10,
		ErrorLog:          slog.NewLogLogger(log.Handler(), slog.LevelWarn),
	}
	ln, err := net.Listen("tcp", cfg.Listen)
	if err != nil {
		return fmt.Errorf("listen %s: %w", cfg.Listen, err)
	}
	log.Info("cg-agent listening",
		"addr", ln.Addr().String(),
		"mode", cfg.Mode,
		"version", version,
		"cache_ttl", cfg.CacheTTL.String(),
		"sql_transport", cfg.SQLTransport,
		"api_base_url", cfg.APIBaseURL,
		"redeem_timeout", a.redeemTimeout.String())

	errCh := make(chan error, 1)
	go func() { errCh <- srv.Serve(ln) }()

	select {
	case <-ctx.Done():
		log.Info("shutdown signal received")
	case err := <-errCh:
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			return fmt.Errorf("http server: %w", err)
		}
	}

	// Graceful shutdown: stop accepting, finish in-flight requests, drain the
	// event queue (bounded), close the DB (deferred).
	sctx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownTimeout)
	defer cancel()
	if err := srv.Shutdown(sctx); err != nil {
		log.Warn("http shutdown", "err", err.Error())
	}
	stop() // cancels ctx for the background workers
	a.queue.Shutdown(cfg.ShutdownTimeout)
	log.Info("cg-agent stopped")
	return nil
}

func (a *app) cacheSweeper(ctx context.Context) {
	t := time.NewTicker(time.Minute)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if n := a.cache.Sweep(); n > 0 {
				a.log.Debug("cache sweep", "expired", n, "size", a.cache.Len())
			}
		}
	}
}
