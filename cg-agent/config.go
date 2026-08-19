package main

import (
	"errors"
	"fmt"
	"net"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Config is the fully-resolved runtime configuration. Defaults are in
// defaultConfig(); the file at /etc/cg-agent/config.toml overrides them; a few
// environment variables override the file (see loadConfig).
type Config struct {
	Mode            string // stub | local | remote
	Listen          string
	LogLevel        string
	ShutdownTimeout time.Duration

	CacheTTL time.Duration
	CacheMax int

	APIBaseURL    string
	APIToken      string
	APITimeout    time.Duration
	APIRetries    int
	APIRedeemPath string
	APIEventPath  string
	APIInsecure   bool

	BreakerFailures int
	BreakerWindow   time.Duration
	BreakerProbe    time.Duration

	QueueSize        int
	QueueWorkers     int
	QueueMaxAttempts int
	QueueRetryBase   time.Duration
	QueueRetryMax    time.Duration

	DBDSN     string
	DBMaxOpen int
	DBMaxIdle int

	SQLTransport bool
	SQLPoll      time.Duration
	SQLBatch     int

	TicketDefaultTTL time.Duration // default ttl for POST /v1/tickets
}

func defaultConfig() Config {
	return Config{
		Mode:            "stub",
		Listen:          "127.0.0.1:8480",
		LogLevel:        "info",
		ShutdownTimeout: 5 * time.Second,

		CacheTTL: 10 * time.Minute,
		CacheMax: 50000,

		APIBaseURL:    "https://api.chogan.games",
		APITimeout:    3 * time.Second,
		APIRetries:    1,
		APIRedeemPath: "/v1/servers/redeem",
		APIEventPath:  "/v1/servers/events",

		BreakerFailures: 5,
		BreakerWindow:   30 * time.Second,
		BreakerProbe:    10 * time.Second,

		QueueSize:        10000,
		QueueWorkers:     1,
		QueueMaxAttempts: 5,
		QueueRetryBase:   500 * time.Millisecond,
		QueueRetryMax:    30 * time.Second,

		DBMaxOpen: 8,
		DBMaxIdle: 4,

		SQLPoll:  250 * time.Millisecond,
		SQLBatch: 50,

		TicketDefaultTTL: 90 * time.Second,
	}
}

// loadConfig reads and validates the config file. It returns non-fatal
// warnings (unknown keys, loose permissions, ...) separately from the error.
func loadConfig(path string) (Config, []string, error) {
	cfg := defaultConfig()
	var warnings []string

	data, err := os.ReadFile(path)
	if err != nil {
		return cfg, nil, fmt.Errorf("read config: %w", err)
	}
	m, err := parseTOML(string(data))
	if err != nil {
		return cfg, nil, fmt.Errorf("parse %s: %w", path, err)
	}
	k := &kv{m: m, used: map[string]bool{}}

	cfg.Mode = strings.ToLower(strings.TrimSpace(k.str("mode", cfg.Mode)))
	cfg.Listen = k.str("listen", cfg.Listen)
	cfg.LogLevel = k.str("log_level", cfg.LogLevel)
	cfg.ShutdownTimeout = k.secs("shutdown_timeout_sec", cfg.ShutdownTimeout)

	cfg.CacheTTL = k.secs("cache.ttl_sec", cfg.CacheTTL)
	cfg.CacheMax = k.num("cache.max_entries", cfg.CacheMax)

	cfg.APIBaseURL = strings.TrimRight(k.str("api.base_url", cfg.APIBaseURL), "/")
	cfg.APIToken = k.str("api.token", cfg.APIToken)
	cfg.APITimeout = k.secs("api.timeout_sec", cfg.APITimeout)
	cfg.APIRetries = k.num("api.retries", cfg.APIRetries)
	cfg.APIRedeemPath = k.str("api.redeem_path", cfg.APIRedeemPath)
	cfg.APIEventPath = k.str("api.event_path", cfg.APIEventPath)
	cfg.APIInsecure = k.boolean("api.insecure_skip_verify", cfg.APIInsecure)

	cfg.BreakerFailures = k.num("breaker.failures", cfg.BreakerFailures)
	cfg.BreakerWindow = k.secs("breaker.window_sec", cfg.BreakerWindow)
	cfg.BreakerProbe = k.secs("breaker.probe_interval_sec", cfg.BreakerProbe)

	cfg.QueueSize = k.num("queue.size", cfg.QueueSize)
	cfg.QueueWorkers = k.num("queue.workers", cfg.QueueWorkers)
	cfg.QueueMaxAttempts = k.num("queue.max_attempts", cfg.QueueMaxAttempts)
	cfg.QueueRetryBase = k.millis("queue.retry_base_ms", cfg.QueueRetryBase)
	cfg.QueueRetryMax = k.millis("queue.retry_max_ms", cfg.QueueRetryMax)

	cfg.DBDSN = k.str("db.dsn", cfg.DBDSN)
	cfg.DBMaxOpen = k.num("db.max_open", cfg.DBMaxOpen)
	cfg.DBMaxIdle = k.num("db.max_idle", cfg.DBMaxIdle)

	// both spellings are accepted: top-level `sql_transport = true` and
	// `[sql_transport] enabled = true`
	cfg.SQLTransport = k.boolean("sql_transport", cfg.SQLTransport)
	cfg.SQLTransport = k.boolean("sql_transport.enabled", cfg.SQLTransport)
	cfg.SQLPoll = k.millis("sql_transport.poll_ms", cfg.SQLPoll)
	cfg.SQLBatch = k.num("sql_transport.batch", cfg.SQLBatch)

	cfg.TicketDefaultTTL = k.secs("tickets.default_ttl_sec", cfg.TicketDefaultTTL)

	for key := range m {
		if !k.used[key] {
			warnings = append(warnings, "unknown config key "+key+" (ignored)")
		}
	}
	sort.Strings(warnings)
	if len(k.errs) > 0 {
		return cfg, warnings, fmt.Errorf("config %s: %s", path, strings.Join(k.errs, "; "))
	}

	// Secrets live in the file; refuse to run if the file is world-readable.
	fileHasSecrets := cfg.APIToken != "" || cfg.DBDSN != ""
	permWarning, err := checkConfigPerms(path, fileHasSecrets)
	if err != nil {
		return cfg, warnings, err
	}
	if permWarning != "" {
		warnings = append(warnings, permWarning)
	}

	// Environment overrides (handy with systemd `Environment=` / credentials).
	if v := os.Getenv("CG_AGENT_MODE"); v != "" {
		cfg.Mode = strings.ToLower(strings.TrimSpace(v))
	}
	if v := os.Getenv("CG_AGENT_LISTEN"); v != "" {
		cfg.Listen = v
	}
	if v := os.Getenv("CG_AGENT_API_TOKEN"); v != "" {
		cfg.APIToken = v
	}
	if v := os.Getenv("CG_AGENT_DB_DSN"); v != "" {
		cfg.DBDSN = v
	}

	if err := cfg.validate(); err != nil {
		return cfg, warnings, err
	}
	warnings = append(warnings, cfg.advisories()...)
	return cfg, warnings, nil
}

func (c *Config) validate() error {
	switch c.Mode {
	case "stub", "local", "remote":
	default:
		return fmt.Errorf("mode must be stub, local or remote (got %q)", c.Mode)
	}
	if c.Listen == "" {
		return errors.New("listen must not be empty")
	}
	if _, _, err := net.SplitHostPort(c.Listen); err != nil {
		return fmt.Errorf("listen %q: %w", c.Listen, err)
	}
	if c.CacheTTL <= 0 {
		return errors.New("cache.ttl_sec must be > 0")
	}
	if c.ShutdownTimeout <= 0 {
		c.ShutdownTimeout = 5 * time.Second
	}
	if c.Mode == "remote" {
		if !strings.HasPrefix(c.APIBaseURL, "https://") && !strings.HasPrefix(c.APIBaseURL, "http://") {
			return fmt.Errorf("api.base_url must start with https:// or http:// (got %q)", c.APIBaseURL)
		}
		if c.APITimeout <= 0 {
			return errors.New("api.timeout_sec must be > 0")
		}
		if c.APIRetries < 0 {
			return errors.New("api.retries must be >= 0")
		}
		if !strings.HasPrefix(c.APIRedeemPath, "/") || !strings.HasPrefix(c.APIEventPath, "/") {
			return errors.New("api.redeem_path and api.event_path must start with /")
		}
	}
	if c.Mode == "local" && c.DBDSN == "" {
		return errors.New("mode = \"local\" requires [db] dsn")
	}
	if c.SQLTransport && c.DBDSN == "" {
		return errors.New("sql_transport = true requires [db] dsn")
	}
	if c.QueueSize <= 0 {
		return errors.New("queue.size must be > 0")
	}
	if c.QueueWorkers <= 0 {
		c.QueueWorkers = 1
	}
	if c.QueueMaxAttempts <= 0 {
		c.QueueMaxAttempts = 1
	}
	if c.QueueRetryBase <= 0 {
		c.QueueRetryBase = 500 * time.Millisecond
	}
	if c.QueueRetryMax < c.QueueRetryBase {
		c.QueueRetryMax = c.QueueRetryBase
	}
	if c.SQLPoll < 50*time.Millisecond {
		return errors.New("sql_transport.poll_ms must be >= 50")
	}
	if c.SQLBatch <= 0 {
		c.SQLBatch = 50
	}
	if c.DBMaxOpen <= 0 {
		c.DBMaxOpen = 8
	}
	if c.DBMaxIdle < 0 {
		c.DBMaxIdle = 0
	}
	if c.TicketDefaultTTL <= 0 {
		c.TicketDefaultTTL = 90 * time.Second
	}
	return nil
}

// advisories are non-fatal things worth a warning in the log at startup.
func (c *Config) advisories() []string {
	var w []string
	if host, _, err := net.SplitHostPort(c.Listen); err == nil {
		if ip := net.ParseIP(host); host != "localhost" && (ip == nil || !ip.IsLoopback()) {
			w = append(w, "listen is not a loopback address; the agent has NO authentication of its own, keep it on 127.0.0.1")
		}
	}
	if c.Mode == "remote" && c.APIToken == "" {
		w = append(w, "mode = remote but api.token is empty; requests go out without Authorization")
	}
	if c.Mode == "remote" && c.APIInsecure {
		w = append(w, "api.insecure_skip_verify = true; TLS certificate of the API is NOT verified")
	}
	if c.Mode == "remote" && strings.HasPrefix(c.APIBaseURL, "http://") {
		w = append(w, "api.base_url is plain http; the bearer token travels in clear text")
	}
	return w
}

// checkConfigPerms enforces MISSION-style secret hygiene: a config that carries
// a DB DSN or API token must not be world-readable.
func checkConfigPerms(path string, hasSecrets bool) (string, error) {
	fi, err := os.Stat(path)
	if err != nil {
		return "", err
	}
	perm := fi.Mode().Perm()
	if perm&0o004 != 0 {
		if hasSecrets {
			return "", fmt.Errorf("%s is world-readable (%04o) but contains secrets; use `chmod 0600` (or 0640 root:cg-agent) and retry", path, perm)
		}
		return fmt.Sprintf("%s is world-readable (%04o); make it 0600 before adding secrets", path, perm), nil
	}
	if perm&0o070 != 0 && hasSecrets {
		return fmt.Sprintf("%s is group-readable (%04o); 0600 recommended", path, perm), nil
	}
	return "", nil
}

// kv wraps the flat map produced by parseTOML with typed, default-aware
// getters. It records which keys were consumed (to warn about typos) and
// collects type errors instead of failing on the first one.
type kv struct {
	m    map[string]any
	used map[string]bool
	errs []string
}

func (k *kv) str(key, def string) string {
	v, ok := k.m[key]
	if !ok {
		return def
	}
	k.used[key] = true
	switch t := v.(type) {
	case string:
		return t
	case int64:
		return strconv.FormatInt(t, 10)
	case float64:
		return strconv.FormatFloat(t, 'f', -1, 64)
	case bool:
		return strconv.FormatBool(t)
	}
	k.errs = append(k.errs, key+": expected a string")
	return def
}

func (k *kv) num(key string, def int) int {
	v, ok := k.m[key]
	if !ok {
		return def
	}
	k.used[key] = true
	switch t := v.(type) {
	case int64:
		return int(t)
	case float64:
		if t == float64(int64(t)) {
			return int(t)
		}
	case string:
		if n, err := strconv.Atoi(strings.TrimSpace(t)); err == nil {
			return n
		}
	}
	k.errs = append(k.errs, key+": expected an integer")
	return def
}

func (k *kv) boolean(key string, def bool) bool {
	v, ok := k.m[key]
	if !ok {
		return def
	}
	k.used[key] = true
	switch t := v.(type) {
	case bool:
		return t
	case string:
		if b, err := strconv.ParseBool(strings.TrimSpace(t)); err == nil {
			return b
		}
	case int64:
		return t != 0
	}
	k.errs = append(k.errs, key+": expected true or false")
	return def
}

func (k *kv) secs(key string, def time.Duration) time.Duration {
	return time.Duration(k.num(key, int(def/time.Second))) * time.Second
}

func (k *kv) millis(key string, def time.Duration) time.Duration {
	return time.Duration(k.num(key, int(def/time.Millisecond))) * time.Millisecond
}

// ---------------------------------------------------------------------------
// Tiny TOML-subset parser.
//
// Supported:
//   - comments: '#' to end of line (outside strings)
//   - [section] headers, one level (the name is used literally, "a.b" is fine)
//   - key = value, key chars [A-Za-z0-9_.-]
//   - values: "basic string" with escapes \" \\ \n \t \r,
//     'literal string' (no escapes), integer (optional sign, '_' separators),
//     float, true, false
//   - blank lines, CRLF line endings
//
// Not supported (an error is returned): arrays, inline tables, multi-line
// strings, dates/times, quoted keys, dotted keys inside a section, [[array]].
// Keys are returned flattened as "section.key" ("key" for the root table).
// ---------------------------------------------------------------------------

func parseTOML(src string) (map[string]any, error) {
	out := make(map[string]any)
	section := ""
	for i, raw := range strings.Split(src, "\n") {
		lineNo := i + 1
		line := strings.TrimSpace(strings.TrimSuffix(raw, "\r"))
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, "[") {
			if strings.HasPrefix(line, "[[") {
				return nil, fmt.Errorf("line %d: arrays of tables are not supported", lineNo)
			}
			end := strings.IndexByte(line, ']')
			if end < 0 {
				return nil, fmt.Errorf("line %d: unterminated section header", lineNo)
			}
			name := strings.TrimSpace(line[1:end])
			if name == "" || !validTOMLKey(name) {
				return nil, fmt.Errorf("line %d: invalid section name %q", lineNo, name)
			}
			if err := ensureOnlyComment(line[end+1:]); err != nil {
				return nil, fmt.Errorf("line %d: %w", lineNo, err)
			}
			section = name
			continue
		}
		eq := strings.IndexByte(line, '=')
		if eq < 0 {
			return nil, fmt.Errorf("line %d: expected `key = value`", lineNo)
		}
		key := strings.TrimSpace(line[:eq])
		if key == "" || !validTOMLKey(key) {
			return nil, fmt.Errorf("line %d: invalid key %q", lineNo, key)
		}
		val, err := parseTOMLValue(strings.TrimSpace(line[eq+1:]))
		if err != nil {
			return nil, fmt.Errorf("line %d: %s: %w", lineNo, key, err)
		}
		full := key
		if section != "" {
			full = section + "." + key
		}
		if _, dup := out[full]; dup {
			return nil, fmt.Errorf("line %d: duplicate key %q", lineNo, full)
		}
		out[full] = val
	}
	return out, nil
}

func validTOMLKey(s string) bool {
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9', c == '_', c == '-', c == '.':
		default:
			return false
		}
	}
	return true
}

func parseTOMLValue(raw string) (any, error) {
	if raw == "" {
		return nil, errors.New("missing value")
	}
	switch raw[0] {
	case '"':
		s, rest, err := parseBasicString(raw)
		if err != nil {
			return nil, err
		}
		if err := ensureOnlyComment(rest); err != nil {
			return nil, err
		}
		return s, nil
	case '\'':
		end := strings.IndexByte(raw[1:], '\'')
		if end < 0 {
			return nil, errors.New("unterminated literal string")
		}
		s := raw[1 : 1+end]
		if err := ensureOnlyComment(raw[2+end:]); err != nil {
			return nil, err
		}
		return s, nil
	case '[', '{':
		return nil, errors.New("arrays and inline tables are not supported")
	}
	if i := strings.IndexByte(raw, '#'); i >= 0 {
		raw = strings.TrimSpace(raw[:i])
	}
	switch raw {
	case "true":
		return true, nil
	case "false":
		return false, nil
	}
	num := strings.ReplaceAll(raw, "_", "")
	if n, err := strconv.ParseInt(num, 10, 64); err == nil {
		return n, nil
	}
	if f, err := strconv.ParseFloat(num, 64); err == nil {
		return f, nil
	}
	return nil, fmt.Errorf("unsupported value %q (use \"string\", 'string', integer, float, true or false)", raw)
}

// parseBasicString parses a "..." string at the start of raw and returns the
// decoded value plus whatever follows the closing quote.
func parseBasicString(raw string) (string, string, error) {
	var b strings.Builder
	for i := 1; i < len(raw); i++ {
		c := raw[i]
		switch c {
		case '"':
			return b.String(), raw[i+1:], nil
		case '\\':
			i++
			if i >= len(raw) {
				return "", "", errors.New("unterminated escape sequence")
			}
			switch raw[i] {
			case '"':
				b.WriteByte('"')
			case '\\':
				b.WriteByte('\\')
			case 'n':
				b.WriteByte('\n')
			case 't':
				b.WriteByte('\t')
			case 'r':
				b.WriteByte('\r')
			default:
				return "", "", fmt.Errorf("unsupported escape \\%c", raw[i])
			}
		default:
			b.WriteByte(c)
		}
	}
	return "", "", errors.New("unterminated string")
}

func ensureOnlyComment(rest string) error {
	rest = strings.TrimSpace(rest)
	if rest == "" || strings.HasPrefix(rest, "#") {
		return nil
	}
	return fmt.Errorf("unexpected text after value: %q", rest)
}
