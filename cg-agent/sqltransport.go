package main

import (
	"context"
	"database/sql"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"
)

// sqlTransport is the MISSION probe-2 fallback transport: if RIPExt cannot do
// async HTTPS from SourcePawn, the plugin INSERTs a row into cg_auth_requests
// with SourceMod's threaded MySQL, this worker resolves it through the very
// same Service.Redeem, writes the verdict back, and the plugin polls the row.
//
// Contract (see deploy/schema.sql):
//
//	plugin:  INSERT INTO cg_auth_requests (ticket, server_id, ip, authid, name) VALUES (...)
//	agent:   every poll_ms: rows WHERE verdict IS NULL -> verdict 'ok'|'fail',
//	         account_id, display_name, phone_masked, source, reason, cache_hit,
//	         api_down, resolved_at; ticket is blanked once resolved
//	plugin:  SELECT verdict, ... FROM cg_auth_requests WHERE id = ? until verdict IS NOT NULL
type sqlTransport struct {
	db            *sql.DB
	svc           *Service
	log           *slog.Logger
	poll          time.Duration
	batch         int
	redeemTimeout time.Duration

	processed atomic.Int64
	errCount  atomic.Int64
	mu        sync.Mutex
	lastErr   string
	lastPoll  time.Time
}

type authRequestRow struct {
	ID       int64
	Ticket   string
	ServerID string
	IP       string
	AuthID   string
	Name     string
}

func newSQLTransport(db *sql.DB, svc *Service, log *slog.Logger, poll time.Duration, batch int, redeemTimeout time.Duration) *sqlTransport {
	if batch <= 0 {
		batch = 50
	}
	return &sqlTransport{db: db, svc: svc, log: log, poll: poll, batch: batch, redeemTimeout: redeemTimeout}
}

func (t *sqlTransport) Run(ctx context.Context) {
	t.log.Info("sql transport started", "poll", t.poll.String(), "batch", t.batch)
	tick := time.NewTicker(t.poll)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
		n, err := t.tick(ctx)
		t.mu.Lock()
		t.lastPoll = time.Now()
		if err != nil {
			t.lastErr = err.Error()
		} else {
			t.lastErr = ""
		}
		t.mu.Unlock()
		if err != nil {
			t.errCount.Add(1)
			if ctx.Err() == nil {
				t.log.Warn("sql transport poll failed", "err", err.Error())
			}
			continue
		}
		// A full batch means there is probably more waiting: poll again at once.
		for n == t.batch && ctx.Err() == nil {
			n, err = t.tick(ctx)
			if err != nil {
				t.errCount.Add(1)
				break
			}
		}
	}
}

// tick fetches up to `batch` pending rows and resolves them one by one.
func (t *sqlTransport) tick(ctx context.Context) (int, error) {
	qctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	rows, err := t.db.QueryContext(qctx,
		`SELECT id, ticket, server_id, ip, authid, name
		   FROM cg_auth_requests WHERE verdict IS NULL ORDER BY id LIMIT ?`, t.batch)
	if err != nil {
		cancel()
		return 0, err
	}
	var pending []authRequestRow
	for rows.Next() {
		var r authRequestRow
		var ticket, serverID, ip, authid, name sql.NullString // tolerate NULLs from the plugin
		if err := rows.Scan(&r.ID, &ticket, &serverID, &ip, &authid, &name); err != nil {
			rows.Close()
			cancel()
			return 0, err
		}
		r.Ticket, r.ServerID, r.IP, r.AuthID, r.Name = ticket.String, serverID.String, ip.String, authid.String, name.String
		pending = append(pending, r)
	}
	err = rows.Err()
	rows.Close()
	cancel()
	if err != nil {
		return 0, err
	}
	for _, r := range pending {
		if ctx.Err() != nil {
			return len(pending), ctx.Err()
		}
		t.resolve(ctx, r)
	}
	return len(pending), nil
}

func (t *sqlTransport) resolve(ctx context.Context, r authRequestRow) {
	rctx, cancelRedeem := context.WithTimeout(ctx, t.redeemTimeout)
	resp := t.svc.Redeem(rctx, RedeemRequest{
		Ticket:   r.Ticket,
		ServerID: r.ServerID,
		IP:       r.IP,
		AuthID:   r.AuthID,
		Name:     r.Name,
	})
	cancelRedeem()

	verdict := "fail"
	if resp.OK {
		verdict = "ok"
	}
	uctx, cancelUpdate := context.WithTimeout(ctx, 5*time.Second)
	defer cancelUpdate()
	res, err := t.db.ExecContext(uctx,
		`UPDATE cg_auth_requests
		    SET verdict = ?, account_id = ?, display_name = ?, phone_masked = ?, source = ?,
		        reason = ?, cache_hit = ?, api_down = ?, ticket = '', resolved_at = NOW()
		  WHERE id = ? AND verdict IS NULL`,
		verdict,
		nullInt64(resp.AccountID),
		nullString(resp.DisplayName),
		nullString(resp.PhoneMasked),
		nullString(resp.Source),
		nullString(resp.Reason),
		resp.CacheHit,
		resp.APIDown,
		r.ID)
	if err != nil {
		t.errCount.Add(1)
		t.log.Error("sql transport: writing verdict failed", "id", r.ID, "err", err.Error())
		return
	}
	updated, _ := res.RowsAffected()
	t.processed.Add(1)
	t.log.Info("redeem (sql transport)",
		"id", r.ID,
		"server_id", r.ServerID,
		"authid", r.AuthID,
		"ip", r.IP,
		"name", r.Name,
		"ok", resp.OK,
		"reason", resp.Reason,
		"source", resp.Source,
		"account_id", resp.AccountID,
		"cache_hit", resp.CacheHit,
		"api_down", resp.APIDown,
		"rows_updated", updated)
}

// sqlTransportStatus is the /health view of the SQL transport worker.
type sqlTransportStatus struct {
	Enabled   bool       `json:"enabled"`
	PollMs    int64      `json:"poll_ms,omitempty"`
	Processed int64      `json:"processed"`
	Errors    int64      `json:"errors"`
	LastError string     `json:"last_error,omitempty"`
	LastPoll  *time.Time `json:"last_poll,omitempty"`
}

func (t *sqlTransport) Status() sqlTransportStatus {
	t.mu.Lock()
	defer t.mu.Unlock()
	st := sqlTransportStatus{
		Enabled:   true,
		PollMs:    t.poll.Milliseconds(),
		Processed: t.processed.Load(),
		Errors:    t.errCount.Load(),
		LastError: t.lastErr,
	}
	if !t.lastPoll.IsZero() {
		lp := t.lastPoll
		st.LastPoll = &lp
	}
	return st
}

func nullInt64(v int64) sql.NullInt64   { return sql.NullInt64{Int64: v, Valid: v != 0} }
func nullString(s string) sql.NullString { return sql.NullString{String: s, Valid: s != ""} }
