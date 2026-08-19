package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"time"
)

var errBreakerOpen = errors.New("circuit breaker open")

// apiError describes a failed call to the Chogan API.
type apiError struct {
	Status      int    // HTTP status, 0 when no response was received
	Body        string // first bytes of the response body (for the log)
	Err         error  // transport / decode error, if any
	Retryable   bool   // network error or 502/503/504 -> one retry is allowed
	BreakerOpen bool   // rejected locally without I/O
}

func (e *apiError) Error() string {
	switch {
	case e.BreakerOpen:
		return errBreakerOpen.Error()
	case e.Err != nil && e.Status == 0:
		return "api: " + e.Err.Error()
	case e.Err != nil:
		return fmt.Sprintf("api: http %d: %v", e.Status, e.Err)
	default:
		return fmt.Sprintf("api: http %d: %s", e.Status, e.Body)
	}
}

func (e *apiError) Unwrap() error { return e.Err }

// remoteBackend talks to https://api.chogan.games (configurable). It is the
// only component that leaves the box. It owns timeouts, the single retry, and
// the circuit breaker; the write queue sits on top of Send.
type remoteBackend struct {
	baseURL    string
	token      string
	redeemPath string
	eventPath  string
	retries    int
	client     *http.Client
	breaker    *Breaker
	log        *slog.Logger
	userAgent  string
}

func newRemoteBackend(cfg Config, br *Breaker, log *slog.Logger) *remoteBackend {
	dialer := &net.Dialer{Timeout: cfg.APITimeout, KeepAlive: 30 * time.Second}
	tr := &http.Transport{
		Proxy:                 http.ProxyFromEnvironment,
		DialContext:           dialer.DialContext,
		ForceAttemptHTTP2:     true,
		MaxIdleConns:          16,
		MaxIdleConnsPerHost:   16,
		IdleConnTimeout:       90 * time.Second,
		TLSHandshakeTimeout:   cfg.APITimeout,
		ExpectContinueTimeout: time.Second,
	}
	if cfg.APIInsecure {
		tr.TLSClientConfig = &tls.Config{InsecureSkipVerify: true} //nolint:gosec // opt-in via config, warned at startup
	}
	return &remoteBackend{
		baseURL:    cfg.APIBaseURL,
		token:      cfg.APIToken,
		redeemPath: cfg.APIRedeemPath,
		eventPath:  cfg.APIEventPath,
		retries:    cfg.APIRetries,
		client:     &http.Client{Transport: tr, Timeout: cfg.APITimeout},
		breaker:    br,
		log:        log,
		userAgent:  "cg-agent/" + version,
	}
}

func (r *remoteBackend) Name() string { return SourceAPI }

// Redeem POSTs the request to the API and maps the response onto the shared
// contract. Retry policy: one extra attempt (api.retries) on network errors and
// 502/503/504, none on 4xx or 500 or when the breaker is open.
func (r *remoteBackend) Redeem(ctx context.Context, req RedeemRequest) (backendResult, error) {
	body, err := json.Marshal(req)
	if err != nil {
		return backendResult{}, err
	}
	var lastErr error
	for attempt := 0; attempt <= r.retries; attempt++ {
		var resp RedeemResponse
		status, err := r.post(ctx, r.redeemPath, body, &resp)
		if err == nil && !resp.OK && resp.Reason == "" {
			err = &apiError{Status: status, Err: errors.New("response has neither ok=true nor a reason")}
		}
		if err == nil {
			return backendResult{
				OK:     resp.OK,
				Reason: resp.Reason,
				Account: Account{
					ID:          resp.AccountID,
					DisplayName: resp.DisplayName,
					PhoneMasked: resp.PhoneMasked,
				},
			}, nil
		}
		lastErr = err
		var ae *apiError
		retryable := errors.As(err, &ae) && ae.Retryable && !ae.BreakerOpen
		r.log.Warn("api redeem failed",
			"attempt", attempt+1,
			"max_attempts", r.retries+1,
			"status", status,
			"retryable", retryable,
			"err", err.Error())
		if !retryable || ctx.Err() != nil {
			break
		}
		if !sleepCtx(ctx, 100*time.Millisecond) {
			break
		}
	}
	return backendResult{}, lastErr
}

// Send delivers one queued event. It never retries by itself; the queue does.
func (r *remoteBackend) Send(ctx context.Context, e Event) (bool, error) {
	body, err := json.Marshal(e)
	if err != nil {
		return false, err
	}
	_, err = r.post(ctx, r.eventPath, body, nil)
	if err == nil {
		return false, nil
	}
	var ae *apiError
	if errors.As(err, &ae) {
		return ae.Retryable, err
	}
	return false, err
}

// post performs one HTTP call, does the breaker accounting, and decodes a 2xx
// JSON body into out (when out != nil and the body is non-empty).
//
// Breaker rules: transport error / 5xx -> Failure; any 4xx or a 2xx with an
// undecodable body -> Success (the API is reachable, the breaker is only there
// to stop us waiting on timeouts). The caller still gets an error for those.
func (r *remoteBackend) post(ctx context.Context, path string, body []byte, out any) (int, error) {
	if !r.breaker.Allow() {
		return 0, &apiError{Err: errBreakerOpen, Retryable: true, BreakerOpen: true}
	}
	endpoint := r.baseURL + path
	hreq, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		r.breaker.Success() // our bug, not the API's
		return 0, &apiError{Err: err}
	}
	hreq.Header.Set("Content-Type", "application/json")
	hreq.Header.Set("Accept", "application/json")
	hreq.Header.Set("User-Agent", r.userAgent)
	if r.token != "" {
		hreq.Header.Set("Authorization", "Bearer "+r.token)
	}
	res, err := r.client.Do(hreq)
	if err != nil {
		r.breaker.Failure()
		return 0, &apiError{Err: err, Retryable: true}
	}
	defer res.Body.Close()
	data, err := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if err != nil {
		r.breaker.Failure()
		return res.StatusCode, &apiError{Status: res.StatusCode, Err: err, Retryable: true}
	}
	switch {
	case res.StatusCode >= 500:
		r.breaker.Failure()
		retry := res.StatusCode == http.StatusBadGateway ||
			res.StatusCode == http.StatusServiceUnavailable ||
			res.StatusCode == http.StatusGatewayTimeout
		return res.StatusCode, &apiError{Status: res.StatusCode, Body: truncate(string(data), 256), Retryable: retry}
	case res.StatusCode >= 300:
		r.breaker.Success()
		return res.StatusCode, &apiError{Status: res.StatusCode, Body: truncate(string(data), 256)}
	}
	r.breaker.Success()
	if out != nil && len(bytes.TrimSpace(data)) > 0 {
		if err := json.Unmarshal(data, out); err != nil {
			return res.StatusCode, &apiError{Status: res.StatusCode, Body: truncate(string(data), 256), Err: fmt.Errorf("decode: %w", err)}
		}
	}
	return res.StatusCode, nil
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}

// sleepCtx sleeps for d or until ctx is done; false means ctx ended first.
func sleepCtx(ctx context.Context, d time.Duration) bool {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-t.C:
		return true
	}
}
