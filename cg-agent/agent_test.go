package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func testLogger() *slog.Logger { return slog.New(slog.NewTextHandler(io.Discard, nil)) }

// --- ticket helpers ---------------------------------------------------------

func TestHashTicket(t *testing.T) {
	const want = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824" // sha256("hello")
	if got := hashTicket("hello"); got != want {
		t.Fatalf("hashTicket(hello) = %s, want %s", got, want)
	}
	if got := hashTicket(""); len(got) != 64 {
		t.Fatalf("hash of empty string has length %d, want 64", len(got))
	}
	if hashTicket("a") == hashTicket("b") {
		t.Fatal("different tickets must not hash equal")
	}
}

func TestStubAccountID(t *testing.T) {
	for _, tk := range []string{"", "x", "hello", "some-long-ticket-value-1234567890"} {
		id := stubAccountID(tk)
		if id < 1000 || id > 1999 {
			t.Fatalf("stubAccountID(%q) = %d, want 1000..1999", tk, id)
		}
		if id != stubAccountID(tk) {
			t.Fatalf("stubAccountID(%q) is not deterministic", tk)
		}
	}
}

func TestNewTicket(t *testing.T) {
	a, err := newTicket()
	if err != nil {
		t.Fatal(err)
	}
	b, err := newTicket()
	if err != nil {
		t.Fatal(err)
	}
	if len(a) != 43 {
		t.Fatalf("ticket length %d, want 43 (32 bytes base64url, no padding)", len(a))
	}
	if a == b {
		t.Fatal("two fresh tickets are equal")
	}
	if strings.ContainsAny(a, "+/=") {
		t.Fatalf("ticket %q is not base64url", a)
	}
}

func TestMaskPhone(t *testing.T) {
	cases := map[string]string{
		"+989121234567": "+989*******67",
		"09121234567":   "091******67",
		"1234":          "****",
		"":              "",
		"abc":           "abc",
	}
	for in, want := range cases {
		if got := maskPhone(in); got != want {
			t.Errorf("maskPhone(%q) = %q, want %q", in, got, want)
		}
	}
}

// --- TOML subset ------------------------------------------------------------

func TestParseTOML(t *testing.T) {
	src := "# comment\n" +
		"mode = \"remote\"   # trailing comment\n" +
		"listen = '127.0.0.1:8480'\n" +
		"sql_transport = true\n" +
		"\n" +
		"[api]\n" +
		"base_url = \"https://api.chogan.games\"\n" +
		"token = \"abc # not a comment\"\n" +
		"timeout_sec = 3\n" +
		"ratio = 1.5\n" +
		"escaped = \"a\\\"b\\\\c\"\n" +
		"big = 1_000\n" +
		"\n" +
		"[breaker]   # section comment\n" +
		"failures = 5\r\n"
	m, err := parseTOML(src)
	if err != nil {
		t.Fatalf("parseTOML: %v", err)
	}
	want := map[string]any{
		"mode":             "remote",
		"listen":           "127.0.0.1:8480",
		"sql_transport":    true,
		"api.base_url":     "https://api.chogan.games",
		"api.token":        "abc # not a comment",
		"api.timeout_sec":  int64(3),
		"api.ratio":        1.5,
		"api.escaped":      `a"b\c`,
		"api.big":          int64(1000),
		"breaker.failures": int64(5),
	}
	for k, v := range want {
		got, ok := m[k]
		if !ok || got != v {
			t.Errorf("%s = %#v (%T), want %#v", k, got, got, v)
		}
	}
	if len(m) != len(want) {
		t.Errorf("parsed %d keys, want %d: %v", len(m), len(want), m)
	}
	for _, bad := range []string{
		"novalue",
		"x = [1,2]",
		"x = {a=1}",
		"x = \"unterminated",
		"[sec\nx=1",
		"x = 1\nx = 2",
		"x = yes",
		"[[arr]]\nx=1",
		"x = \"a\" trailing",
	} {
		if _, err := parseTOML(bad); err == nil {
			t.Errorf("expected an error for %q", bad)
		}
	}
}

func TestLoadConfig(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "config.toml")
	src := "mode = \"stub\"\nlisten = \"127.0.0.1:8481\"\n[cache]\nttl_sec = 120\n[queue]\nsize = 5\nbogus = 1\n"
	if err := os.WriteFile(p, []byte(src), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, warnings, err := loadConfig(p)
	if err != nil {
		t.Fatalf("loadConfig: %v", err)
	}
	if cfg.Mode != "stub" || cfg.Listen != "127.0.0.1:8481" || cfg.CacheTTL != 120*time.Second || cfg.QueueSize != 5 {
		t.Fatalf("unexpected config: %+v", cfg)
	}
	found := false
	for _, w := range warnings {
		if strings.Contains(w, "queue.bogus") {
			found = true
		}
	}
	if !found {
		t.Fatalf("expected an unknown-key warning, got %v", warnings)
	}

	if err := os.WriteFile(p, []byte("mode = \"local\"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := loadConfig(p); err == nil {
		t.Fatal("mode=local without a dsn must be rejected")
	}

	if runtime.GOOS != "windows" {
		if err := os.WriteFile(p, []byte("mode = \"remote\"\n[api]\ntoken = \"s\"\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(p, 0o644); err != nil {
			t.Fatal(err)
		}
		if _, _, err := loadConfig(p); err == nil {
			t.Fatal("a world-readable config that contains secrets must be rejected")
		}
	}
}

// --- breaker ----------------------------------------------------------------

func TestBreaker(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	b := NewBreaker(3, 10*time.Second, 5*time.Second)
	b.now = func() time.Time { return now }

	for i := 0; i < 2; i++ {
		if !b.Allow() {
			t.Fatal("closed breaker must allow")
		}
		b.Failure()
	}
	if b.State() != BreakerClosed {
		t.Fatalf("state after 2 failures = %v, want closed", b.State())
	}
	if !b.Allow() {
		t.Fatal("still closed, must allow")
	}
	b.Failure()
	if b.State() != BreakerOpen {
		t.Fatalf("state after 3 failures = %v, want open", b.State())
	}
	if b.Allow() {
		t.Fatal("open breaker must reject")
	}
	now = now.Add(4 * time.Second)
	if b.Allow() {
		t.Fatal("must still reject before the probe interval")
	}
	now = now.Add(2 * time.Second)
	if !b.Allow() {
		t.Fatal("must allow one probe after the probe interval")
	}
	if b.State() != BreakerHalfOpen {
		t.Fatalf("state = %v, want half_open", b.State())
	}
	if b.Allow() {
		t.Fatal("only one probe at a time")
	}
	b.Failure()
	if b.State() != BreakerOpen {
		t.Fatal("a failed probe must re-open the breaker")
	}
	now = now.Add(5 * time.Second)
	if !b.Allow() {
		t.Fatal("next probe must be allowed")
	}
	b.Success()
	if b.State() != BreakerClosed {
		t.Fatalf("state after successful probe = %v, want closed", b.State())
	}
	if !b.Allow() {
		t.Fatal("closed again, must allow")
	}

	// old failures age out of the window
	b.Failure()
	b.Failure()
	now = now.Add(11 * time.Second)
	b.Failure()
	if b.State() != BreakerClosed {
		t.Fatal("failures older than the window must not count")
	}
	st := b.Status()
	if st.State != "closed" || st.FailuresInWindow != 1 || st.OpensTotal != 2 {
		t.Fatalf("status = %+v", st)
	}

	// threshold 0 disables the breaker
	d := NewBreaker(0, time.Second, time.Second)
	for i := 0; i < 10; i++ {
		d.Failure()
	}
	if !d.Allow() {
		t.Fatal("disabled breaker must always allow")
	}
	if d.Status().State != "disabled" {
		t.Fatalf("status = %+v", d.Status())
	}
}

// --- cache ------------------------------------------------------------------

func TestCacheTTLAndCapacity(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	c := NewCache(10*time.Minute, 2)
	c.now = func() time.Time { return now }
	key := keyIdentity("STEAM_0:1:1", "1.2.3.4")
	c.Set(key, cachedRedemption{Account: Account{ID: 1001, DisplayName: "A"}, AuthID: "STEAM_0:1:1", IP: "1.2.3.4"})
	e, ok := c.Get(key)
	if !ok || e.Account.ID != 1001 {
		t.Fatalf("Get = %+v, %v", e, ok)
	}
	now = now.Add(10*time.Minute + time.Second)
	if _, ok := c.Get(key); ok {
		t.Fatal("expired entry must not be served")
	}
	c.Set("k1", cachedRedemption{})
	c.Set("k2", cachedRedemption{})
	c.Set("k3", cachedRedemption{})
	if c.Len() > 2 {
		t.Fatalf("capacity not enforced: len=%d", c.Len())
	}
	if _, ok := c.Get("k3"); !ok {
		t.Fatal("the entry just set must survive eviction")
	}
	if n := c.Flush(); n == 0 {
		t.Fatal("flush should have removed entries")
	}
	if c.Len() != 0 {
		t.Fatalf("len after flush = %d", c.Len())
	}
}

// --- service ----------------------------------------------------------------

type fakeBackend struct {
	name   string
	fail   atomic.Bool
	result backendResult
	calls  atomic.Int64
}

func (f *fakeBackend) Name() string { return f.name }

func (f *fakeBackend) Redeem(_ context.Context, _ RedeemRequest) (backendResult, error) {
	f.calls.Add(1)
	if f.fail.Load() {
		return backendResult{}, errors.New("boom")
	}
	return f.result, nil
}

func TestServiceStubAndReconnect(t *testing.T) {
	svc := NewService(stubBackend{}, NewCache(10*time.Minute, 100), testLogger())
	ctx := context.Background()
	req := RedeemRequest{Ticket: "ticket-1", ServerID: "pub1", IP: "1.2.3.4", AuthID: "STEAM_0:1:1", Name: "p"}

	r1 := svc.Redeem(ctx, req)
	if !r1.OK || r1.Source != SourceStub || r1.AccountID < 1000 || r1.AccountID > 1999 || r1.Guest || r1.CacheHit || r1.APIDown || r1.DisplayName != "Test Player" {
		t.Fatalf("first redeem = %+v", r1)
	}
	// manual reconnect with the same (already used) ticket from the same authid+ip
	r2 := svc.Redeem(ctx, req)
	if !r2.OK || r2.Source != SourceCache || !r2.CacheHit || r2.APIDown || r2.AccountID != r1.AccountID {
		t.Fatalf("reconnect = %+v", r2)
	}
	// same ticket from a different ip is not the cached path
	req2 := req
	req2.IP = "5.6.7.8"
	if r3 := svc.Redeem(ctx, req2); !r3.OK || r3.Source != SourceStub {
		t.Fatalf("different ip = %+v", r3)
	}
	// empty ticket
	if r4 := svc.Redeem(ctx, RedeemRequest{ServerID: "pub1"}); r4.OK || r4.Reason != ReasonInvalid {
		t.Fatalf("empty ticket = %+v", r4)
	}
	if st := svc.Status(); st.Total != 4 || st.OK != 3 || st.Denied != 1 || st.CacheServed != 1 {
		t.Fatalf("status = %+v", st)
	}
}

func TestServiceAPIDownFallsBackToCache(t *testing.T) {
	fb := &fakeBackend{name: SourceAPI, result: backendResult{OK: true, Account: Account{ID: 42, DisplayName: "Neo", PhoneMasked: "+989*******67"}}}
	svc := NewService(fb, NewCache(10*time.Minute, 100), testLogger())
	ctx := context.Background()
	req := RedeemRequest{Ticket: "t1", ServerID: "pub1", IP: "1.2.3.4", AuthID: "STEAM_0:1:1"}

	if r := svc.Redeem(ctx, req); !r.OK || r.Source != SourceAPI || r.AccountID != 42 || r.CacheHit || r.APIDown {
		t.Fatalf("api ok = %+v", r)
	}
	fb.fail.Store(true)

	// new ticket, known identity -> served from cache, flagged api_down
	req.Ticket = "t2"
	r := svc.Redeem(ctx, req)
	if !r.OK || r.Source != SourceCache || !r.CacheHit || !r.APIDown || r.AccountID != 42 || r.DisplayName != "Neo" {
		t.Fatalf("cache fallback = %+v", r)
	}
	// unknown identity -> ok:false api_down (plugin applies mode 1/2 policy)
	r = svc.Redeem(ctx, RedeemRequest{Ticket: "t3", ServerID: "pub1", IP: "9.9.9.9", AuthID: "STEAM_0:1:2"})
	if r.OK || r.Reason != ReasonAPIDown || !r.APIDown || r.CacheHit {
		t.Fatalf("api down, no cache = %+v", r)
	}
	// backend denial passes through untouched
	fb.fail.Store(false)
	fb.result = backendResult{Reason: ReasonUsed}
	r = svc.Redeem(ctx, RedeemRequest{Ticket: "t4", ServerID: "pub1", IP: "9.9.9.9", AuthID: "STEAM_0:1:2"})
	if r.OK || r.Reason != ReasonUsed || r.APIDown || r.CacheHit {
		t.Fatalf("denial = %+v", r)
	}
}

// --- remote backend ---------------------------------------------------------

func TestRemoteBackendContractAndBreaker(t *testing.T) {
	var mode atomic.Int32 // 0 = ok, 1 = 503, 2 = ok:false used
	var gotAuth atomic.Value
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/servers/redeem" || r.Method != http.MethodPost {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		gotAuth.Store(r.Header.Get("Authorization"))
		var req RedeemRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Ticket == "" {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		switch mode.Load() {
		case 1:
			w.WriteHeader(http.StatusServiceUnavailable)
		case 2:
			writeJSON(w, http.StatusOK, RedeemResponse{OK: false, Reason: ReasonUsed})
		default:
			writeJSON(w, http.StatusOK, RedeemResponse{OK: true, AccountID: 7, DisplayName: "Seven", PhoneMasked: "+989*******07"})
		}
	}))
	defer srv.Close()

	cfg := defaultConfig()
	cfg.APIBaseURL = srv.URL
	cfg.APIToken = "secret"
	cfg.APITimeout = 2 * time.Second
	cfg.APIRetries = 1
	br := NewBreaker(2, 30*time.Second, 10*time.Second)
	rb := newRemoteBackend(cfg, br, testLogger())
	ctx := context.Background()
	req := RedeemRequest{Ticket: "x", ServerID: "pub1", IP: "1.2.3.4", AuthID: "STEAM_0:1:1", Name: "p"}

	res, err := rb.Redeem(ctx, req)
	if err != nil || !res.OK || res.Account.ID != 7 || res.Account.DisplayName != "Seven" || res.Account.PhoneMasked != "+989*******07" {
		t.Fatalf("ok: res=%+v err=%v", res, err)
	}
	if got, _ := gotAuth.Load().(string); got != "Bearer secret" {
		t.Fatalf("Authorization = %q, want Bearer secret", got)
	}

	mode.Store(2)
	res, err = rb.Redeem(ctx, req)
	if err != nil || res.OK || res.Reason != ReasonUsed {
		t.Fatalf("used: res=%+v err=%v", res, err)
	}
	if br.State() != BreakerClosed {
		t.Fatalf("a policy denial must not trip the breaker, state=%v", br.State())
	}

	mode.Store(1) // 503 on both attempts -> 2 failures -> breaker (threshold 2) opens
	if _, err = rb.Redeem(ctx, req); err == nil {
		t.Fatal("expected an error on 503")
	}
	if br.State() != BreakerOpen {
		t.Fatalf("breaker state = %v, want open", br.State())
	}
	if _, err = rb.Redeem(ctx, req); !errors.Is(err, errBreakerOpen) {
		t.Fatalf("expected breaker-open error, got %v", err)
	}
	if st := br.Status(); st.RejectedTotal == 0 || st.OpensTotal != 1 {
		t.Fatalf("breaker status = %+v", st)
	}
}

// --- queue ------------------------------------------------------------------

type countingSink struct {
	sent      atomic.Int64
	failFirst atomic.Int64 // number of leading calls that fail (retryable)
}

func (s *countingSink) Send(_ context.Context, _ Event) (bool, error) {
	if s.failFirst.Load() > 0 {
		s.failFirst.Add(-1)
		return true, errors.New("transient")
	}
	s.sent.Add(1)
	return false, nil
}

func TestQueueDeliversAndRetries(t *testing.T) {
	sink := &countingSink{}
	sink.failFirst.Store(2)
	q := NewQueue(8, 1, 5, time.Millisecond, 5*time.Millisecond, sink, testLogger())
	q.Start()
	for i := 0; i < 3; i++ {
		if !q.Enqueue(Event{ServerID: "pub1", Type: "t"}) {
			t.Fatal("enqueue failed")
		}
	}
	q.Shutdown(2 * time.Second)
	if got := sink.sent.Load(); got != 3 {
		t.Fatalf("sent %d events, want 3", got)
	}
	if st := q.Status(); st.Sent != 3 || st.FailedAttempts != 2 || st.Dropped != 0 || st.Enqueued != 3 {
		t.Fatalf("status = %+v", st)
	}
	if q.Enqueue(Event{}) {
		t.Fatal("enqueue after shutdown must be refused")
	}

	// a full queue drops instead of blocking
	q2 := NewQueue(1, 1, 1, time.Millisecond, time.Millisecond, &countingSink{}, testLogger()) // never started: nobody drains
	if !q2.Enqueue(Event{}) {
		t.Fatal("first enqueue must succeed")
	}
	if q2.Enqueue(Event{}) {
		t.Fatal("second enqueue into a full queue must be dropped")
	}
	if q2.Status().Dropped != 1 {
		t.Fatalf("status = %+v", q2.Status())
	}
}

// --- HTTP layer -------------------------------------------------------------

func newTestApp(t *testing.T) *app {
	t.Helper()
	cfg := defaultConfig()
	log := testLogger()
	c := NewCache(cfg.CacheTTL, cfg.CacheMax)
	q := NewQueue(10, 1, 3, time.Millisecond, 10*time.Millisecond, &countingSink{}, log)
	q.Start()
	t.Cleanup(func() { q.Shutdown(time.Second) })
	return &app{
		cfg:           cfg,
		log:           log,
		svc:           NewService(stubBackend{}, c, log),
		cache:         c,
		queue:         q,
		started:       time.Now(),
		redeemTimeout: 2 * time.Second,
	}
}

func TestHTTPStubMode(t *testing.T) {
	a := newTestApp(t)
	h := a.routes()
	do := func(method, path, body string) (*httptest.ResponseRecorder, map[string]any) {
		req := httptest.NewRequest(method, path, strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		var out map[string]any
		_ = json.Unmarshal(rec.Body.Bytes(), &out)
		return rec, out
	}
	const redeemBody = `{"ticket":"abc","server_id":"pub1","ip":"1.2.3.4","authid":"STEAM_0:1:1","name":"p"}`

	rec, out := do(http.MethodPost, "/v1/redeem", redeemBody)
	if rec.Code != http.StatusOK || out["ok"] != true || out["source"] != "stub" || out["display_name"] != "Test Player" || out["api_down"] != false {
		t.Fatalf("redeem: %d %s", rec.Code, rec.Body.String())
	}
	if _, has := out["guest"]; !has {
		t.Fatalf("guest must always be present: %s", rec.Body.String())
	}
	rec, out = do(http.MethodPost, "/v1/redeem", redeemBody)
	if rec.Code != http.StatusOK || out["ok"] != true || out["source"] != "cache" || out["cache_hit"] != true {
		t.Fatalf("reconnect: %d %s", rec.Code, rec.Body.String())
	}
	rec, out = do(http.MethodPost, "/v1/redeem", `{"ticket":"","server_id":"pub1"}`)
	if rec.Code != http.StatusOK || out["ok"] != false || out["reason"] != "invalid" {
		t.Fatalf("empty ticket: %d %s", rec.Code, rec.Body.String())
	}
	if rec, _ = do(http.MethodPost, "/v1/redeem", `{"ticket":"abc"}`); rec.Code != http.StatusBadRequest {
		t.Fatalf("missing server_id: %d %s", rec.Code, rec.Body.String())
	}
	if rec, _ = do(http.MethodPost, "/v1/redeem", `not json`); rec.Code != http.StatusBadRequest {
		t.Fatalf("bad json: %d %s", rec.Code, rec.Body.String())
	}
	if rec, _ = do(http.MethodGet, "/v1/redeem", ""); rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("GET redeem: %d", rec.Code)
	}

	rec, out = do(http.MethodGet, "/health", "")
	if rec.Code != http.StatusOK || out["status"] != "ok" || out["mode"] != "stub" {
		t.Fatalf("health: %d %s", rec.Code, rec.Body.String())
	}

	rec, out = do(http.MethodPost, "/v1/event", `{"server_id":"pub1","account_id":1001,"type":"connect","payload":{"map":"de_dust2"}}`)
	if rec.Code != http.StatusAccepted || out["queued"] != true {
		t.Fatalf("event: %d %s", rec.Code, rec.Body.String())
	}
	if rec, _ = do(http.MethodPost, "/v1/event", `{"server_id":"pub1"}`); rec.Code != http.StatusBadRequest {
		t.Fatalf("event without type: %d", rec.Code)
	}

	rec, out = do(http.MethodGet, "/v1/cache?authid=STEAM_0:1:1&ip=1.2.3.4", "")
	if rec.Code != http.StatusOK || out["hit"] != true {
		t.Fatalf("cache lookup: %d %s", rec.Code, rec.Body.String())
	}
	rec, out = do(http.MethodGet, "/v1/cache?authid=nobody&ip=0.0.0.0", "")
	if rec.Code != http.StatusOK || out["hit"] != false {
		t.Fatalf("cache miss: %d %s", rec.Code, rec.Body.String())
	}

	rec, out = do(http.MethodPost, "/v1/tickets", `{"account_id":1001,"server_id":"pub1","ttl_sec":90}`)
	if rec.Code != http.StatusOK || out["ticket"] == nil || out["hash"] == nil {
		t.Fatalf("tickets (stub): %d %s", rec.Code, rec.Body.String())
	}

	rec, out = do(http.MethodPost, "/v1/cache/flush", "")
	if rec.Code != http.StatusOK || out["flushed"] == nil {
		t.Fatalf("flush: %d %s", rec.Code, rec.Body.String())
	}
	if rec, _ = do(http.MethodGet, "/nope", ""); rec.Code != http.StatusNotFound {
		t.Fatalf("unknown path: %d", rec.Code)
	}
}
