package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"runtime/debug"
	"strings"
	"time"
)

// maxBodyBytes caps request bodies from the plugin (they are tiny).
const maxBodyBytes = 64 << 10

// routes builds the HTTP API. There is no authentication: the agent must only
// ever listen on loopback (config.go warns otherwise).
func (a *app) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", a.handleHealth)
	mux.HandleFunc("/v1/redeem", a.handleRedeem)
	mux.HandleFunc("/v1/event", a.handleEvent)
	mux.HandleFunc("/v1/tickets", a.handleTickets)
	mux.HandleFunc("/v1/cache", a.handleCache)
	mux.HandleFunc("/v1/cache/flush", a.handleCacheFlush)
	return a.recoverer(mux)
}

// recoverer turns a panic in a handler into a 500 (the only 5xx the agent
// ever returns to the plugin: an agent bug, never a policy outcome).
func (a *app) recoverer(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if rec := recover(); rec != nil {
				a.log.Error("panic in handler",
					"method", r.Method,
					"path", r.URL.Path,
					"panic", fmt.Sprint(rec),
					"stack", string(debug.Stack()))
				writeJSON(w, http.StatusInternalServerError, errorBody("internal error"))
			}
		}()
		next.ServeHTTP(w, r)
	})
}

type healthResponse struct {
	Status       string             `json:"status"` // ok | degraded
	Version      string             `json:"version"`
	Mode         string             `json:"mode"`
	Listen       string             `json:"listen"`
	StartedAt    time.Time          `json:"started_at"`
	UptimeSec    int64              `json:"uptime_sec"`
	Breaker      BreakerStatus      `json:"breaker"`
	Cache        cacheStatus        `json:"cache"`
	Queue        queueStatus        `json:"queue"`
	DB           dbStatus           `json:"db"`
	SQLTransport sqlTransportStatus `json:"sql_transport"`
	Redeem       redeemStatus       `json:"redeem"`
	Degraded     []string           `json:"degraded_reasons,omitempty"`
}

type cacheStatus struct {
	Size   int   `json:"size"`
	TTLSec int   `json:"ttl_sec"`
	Hits   int64 `json:"hits"`
	Misses int64 `json:"misses"`
}

// GET /health -> always 200; look at .status ("ok" | "degraded") and
// .degraded_reasons. It stays 200 on purpose so that a naive `curl -f` based
// watchdog does not restart a perfectly healthy agent just because the API is
// down (that would throw away the cache players are being served from).
func (a *app) handleHealth(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		methodNotAllowed(w, "GET")
		return
	}
	size, hits, misses := a.cache.Stats()
	h := healthResponse{
		Status:    "ok",
		Version:   version,
		Mode:      a.cfg.Mode,
		Listen:    a.cfg.Listen,
		StartedAt: a.started.UTC(),
		UptimeSec: int64(time.Since(a.started).Seconds()),
		Cache:     cacheStatus{Size: size, TTLSec: int(a.cache.TTL() / time.Second), Hits: hits, Misses: misses},
		Queue:     a.queue.Status(),
		Redeem:    a.svc.Status(),
	}
	if a.breaker != nil {
		h.Breaker = a.breaker.Status()
		if h.Breaker.State != "closed" && h.Breaker.State != "disabled" {
			h.Degraded = append(h.Degraded, "breaker "+h.Breaker.State)
		}
	} else {
		h.Breaker = BreakerStatus{State: "disabled"}
	}
	if a.dbmon != nil {
		h.DB = a.dbmon.Status()
		if !h.DB.OK {
			h.Degraded = append(h.Degraded, "db unreachable")
		}
	}
	if a.sqlt != nil {
		h.SQLTransport = a.sqlt.Status()
	}
	if len(h.Degraded) > 0 {
		h.Status = "degraded"
	}
	writeJSON(w, http.StatusOK, h)
}

// POST /v1/redeem {ticket, server_id, ip, authid, name}
// -> 200 {ok:true, account_id, display_name, phone_masked, source, cache_hit, api_down}
// -> 200 {ok:false, reason:"invalid|expired|used|scope|api_down", cache_hit, api_down}
// -> 400 only for malformed JSON / missing server_id (plugin bug), 500 only for agent bugs.
func (a *app) handleRedeem(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w, "POST")
		return
	}
	var req RedeemRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	if strings.TrimSpace(req.ServerID) == "" {
		writeJSON(w, http.StatusBadRequest, errorBody("server_id is required"))
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), a.redeemTimeout)
	defer cancel()
	start := time.Now()
	resp := a.svc.Redeem(ctx, req)
	a.log.Info("redeem",
		"server_id", req.ServerID,
		"authid", req.AuthID,
		"ip", req.IP,
		"name", req.Name,
		"ok", resp.OK,
		"reason", resp.Reason,
		"source", resp.Source,
		"account_id", resp.AccountID,
		"cache_hit", resp.CacheHit,
		"api_down", resp.APIDown,
		"ms", time.Since(start).Milliseconds())
	writeJSON(w, http.StatusOK, resp)
}

// POST /v1/event {server_id, account_id, type, payload}
// -> 202 {queued:true} | 200 {queued:false, reason:"queue_full"}
func (a *app) handleEvent(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w, "POST")
		return
	}
	var e Event
	if !decodeJSON(w, r, &e) {
		return
	}
	if strings.TrimSpace(e.ServerID) == "" || strings.TrimSpace(e.Type) == "" {
		writeJSON(w, http.StatusBadRequest, errorBody("server_id and type are required"))
		return
	}
	if len(e.Payload) > 16<<10 {
		writeJSON(w, http.StatusBadRequest, errorBody("payload larger than 16 KiB"))
		return
	}
	e.At = time.Now().UTC()
	if a.queue.Enqueue(e) {
		writeJSON(w, http.StatusAccepted, map[string]any{"queued": true})
		return
	}
	a.log.Warn("event queue full, event dropped", "type", e.Type, "server_id", e.ServerID)
	writeJSON(w, http.StatusOK, map[string]any{"queued": false, "reason": "queue_full"})
}

type issueRequest struct {
	AccountID int64  `json:"account_id"`
	ServerID  string `json:"server_id"`
	TTLSec    int    `json:"ttl_sec"`
}

// POST /v1/tickets {account_id, server_id, ttl_sec} -> {ticket, hash, expires_at, ...}
// local mode: real ticket in the DB (plaintext returned once, hash stored).
// stub mode: a random ticket (stub accepts anything anyway; useful for scripts).
// remote mode: 404, tickets are issued by the Chogan API / launcher.
func (a *app) handleTickets(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w, "POST")
		return
	}
	var req issueRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	if strings.TrimSpace(req.ServerID) == "" {
		writeJSON(w, http.StatusBadRequest, errorBody("server_id is required"))
		return
	}
	if req.AccountID <= 0 {
		writeJSON(w, http.StatusBadRequest, errorBody("account_id must be > 0"))
		return
	}
	ttl := a.cfg.TicketDefaultTTL
	if req.TTLSec > 0 {
		ttl = time.Duration(req.TTLSec) * time.Second
	}
	if ttl > 24*time.Hour {
		ttl = 24 * time.Hour
	}
	switch a.cfg.Mode {
	case "remote":
		writeJSON(w, http.StatusNotFound, errorBody("tickets are issued by the Chogan API in remote mode"))
	case "stub":
		t, err := newTicket()
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, errorBody("random source failed"))
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"ticket":     t,
			"hash":       hashTicket(t),
			"account_id": stubAccountID(t),
			"server_id":  req.ServerID,
			"expires_at": time.Now().UTC().Add(ttl),
			"note":       "stub mode: any non-empty ticket is accepted; account_id is derived from the ticket, not from the request",
		})
	default: // local
		if a.local == nil {
			writeJSON(w, http.StatusServiceUnavailable, errorBody("no database configured"))
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		defer cancel()
		ticket, hash, exp, err := a.local.Issue(ctx, req.AccountID, req.ServerID, ttl)
		if err != nil {
			a.log.Error("issue ticket failed", "err", err.Error())
			writeJSON(w, http.StatusServiceUnavailable, errorBody("database error: "+err.Error()))
			return
		}
		a.log.Info("ticket issued", "account_id", req.AccountID, "server_id", req.ServerID, "ttl_sec", int(ttl/time.Second), "hash", hash)
		writeJSON(w, http.StatusOK, map[string]any{
			"ticket":     ticket,
			"hash":       hash,
			"account_id": req.AccountID,
			"server_id":  req.ServerID,
			"expires_at": exp,
		})
	}
}

// GET /v1/cache?authid=&ip= -> {hit, account_id, display_name, phone_masked, expires_at}
func (a *app) handleCache(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w, "GET")
		return
	}
	authid := r.URL.Query().Get("authid")
	ip := r.URL.Query().Get("ip")
	e, ok := a.cache.Get(keyIdentity(authid, ip))
	if !ok {
		writeJSON(w, http.StatusOK, map[string]any{"hit": false})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"hit":          true,
		"account_id":   e.Account.ID,
		"display_name": e.Account.DisplayName,
		"phone_masked": e.Account.PhoneMasked,
		"expires_at":   e.Exp.UTC(),
	})
}

// POST|DELETE /v1/cache/flush -> {flushed: n}
func (a *app) handleCacheFlush(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost && r.Method != http.MethodDelete {
		methodNotAllowed(w, "POST, DELETE")
		return
	}
	n := a.cache.Flush()
	a.log.Info("cache flushed", "entries", n)
	writeJSON(w, http.StatusOK, map[string]any{"flushed": n})
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func decodeJSON(w http.ResponseWriter, r *http.Request, v any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
	if err := json.NewDecoder(r.Body).Decode(v); err != nil {
		writeJSON(w, http.StatusBadRequest, errorBody("invalid json: "+err.Error()))
		return false
	}
	return true
}

func methodNotAllowed(w http.ResponseWriter, allow string) {
	w.Header().Set("Allow", allow)
	writeJSON(w, http.StatusMethodNotAllowed, errorBody("method not allowed"))
}

func errorBody(msg string) map[string]string { return map[string]string{"error": msg} }
