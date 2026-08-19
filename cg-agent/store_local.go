package main

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/go-sql-driver/mysql"
)

// openDB opens the MariaDB pool. The DSN comes from [db] dsn, e.g.
//
//	cgagent:secret@tcp(127.0.0.1:3306)/chogan
//
// parseTime=true is forced (DATETIME -> time.Time) and sane timeouts are
// added when the DSN does not set them. The pool is lazy: a DB that is down at
// startup only shows up in /health, it does not stop the agent.
func openDB(cfg Config) (*sql.DB, error) {
	mc, err := mysql.ParseDSN(cfg.DBDSN)
	if err != nil {
		return nil, fmt.Errorf("parse db dsn: %w", err)
	}
	mc.ParseTime = true
	if mc.Timeout == 0 {
		mc.Timeout = 3 * time.Second
	}
	if mc.ReadTimeout == 0 {
		mc.ReadTimeout = 5 * time.Second
	}
	if mc.WriteTimeout == 0 {
		mc.WriteTimeout = 5 * time.Second
	}
	db, err := sql.Open("mysql", mc.FormatDSN())
	if err != nil {
		return nil, fmt.Errorf("open db: %w", err)
	}
	db.SetMaxOpenConns(cfg.DBMaxOpen)
	db.SetMaxIdleConns(cfg.DBMaxIdle)
	db.SetConnMaxLifetime(5 * time.Minute)
	db.SetConnMaxIdleTime(2 * time.Minute)
	return db, nil
}

// localStore is the "local" backend: the agent owns the tickets/accounts
// tables in MariaDB and redeems with the exact atomic UPDATE from MISSION 6.3.
// It also serves as the event sink (cg_events) in local mode and issues test
// tickets for POST /v1/tickets.
type localStore struct {
	db  *sql.DB
	log *slog.Logger
}

func (s *localStore) Name() string { return SourceLocal }

// Redeem: UPDATE ... SET used_at=NOW() WHERE hash=? AND used_at IS NULL AND
// exp>NOW() AND server_id=?; exactly one row affected means success. Otherwise
// a second SELECT explains why (invalid / used / expired / scope).
func (s *localStore) Redeem(ctx context.Context, req RedeemRequest) (backendResult, error) {
	if req.Ticket == "" {
		return backendResult{Reason: ReasonInvalid}, nil
	}
	h := hashTicket(req.Ticket)
	res, err := s.db.ExecContext(ctx,
		`UPDATE tickets SET used_at = NOW()
		  WHERE hash = ? AND used_at IS NULL AND exp > NOW() AND server_id = ?`,
		h, req.ServerID)
	if err != nil {
		return backendResult{}, fmt.Errorf("redeem update: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return backendResult{}, fmt.Errorf("redeem rows affected: %w", err)
	}
	if n == 1 {
		var accountID int64
		var phone, display sql.NullString
		err := s.db.QueryRowContext(ctx,
			`SELECT t.account_id, a.phone, a.display_name
			   FROM tickets t LEFT JOIN accounts a ON a.id = t.account_id
			  WHERE t.hash = ?`, h).Scan(&accountID, &phone, &display)
		if err != nil {
			return backendResult{}, fmt.Errorf("redeem select: %w", err)
		}
		name := display.String
		if name == "" {
			name = fmt.Sprintf("Player %d", accountID)
		}
		return backendResult{OK: true, Account: Account{
			ID:          accountID,
			DisplayName: name,
			PhoneMasked: maskPhone(phone.String),
		}}, nil
	}

	// Not redeemed. Find out why (best effort; the plugin only needs a reason).
	var serverID string
	var exp, now time.Time
	var usedAt sql.NullTime
	err = s.db.QueryRowContext(ctx,
		`SELECT server_id, exp, used_at, NOW() FROM tickets WHERE hash = ?`, h,
	).Scan(&serverID, &exp, &usedAt, &now)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return backendResult{Reason: ReasonInvalid}, nil
	case err != nil:
		return backendResult{}, fmt.Errorf("redeem diagnose: %w", err)
	case serverID != req.ServerID:
		return backendResult{Reason: ReasonScope}, nil
	case usedAt.Valid:
		return backendResult{Reason: ReasonUsed}, nil
	case !exp.After(now):
		return backendResult{Reason: ReasonExpired}, nil
	}
	return backendResult{Reason: ReasonInvalid}, nil
}

// Issue creates a ticket for accountID scoped to serverID. Only the SHA-256 is
// stored; the plaintext is returned once. Expiry is computed by the DB clock so
// it is consistent with the NOW() used at redeem time.
func (s *localStore) Issue(ctx context.Context, accountID int64, serverID string, ttl time.Duration) (ticket, hash string, exp time.Time, err error) {
	ticket, err = newTicket()
	if err != nil {
		return "", "", time.Time{}, err
	}
	hash = hashTicket(ticket)
	_, err = s.db.ExecContext(ctx,
		`INSERT INTO tickets (hash, account_id, server_id, exp, created_at)
		 VALUES (?, ?, ?, DATE_ADD(NOW(), INTERVAL ? SECOND), NOW())`,
		hash, accountID, serverID, int64(ttl/time.Second))
	if err != nil {
		return "", "", time.Time{}, fmt.Errorf("insert ticket: %w", err)
	}
	if err = s.db.QueryRowContext(ctx, `SELECT exp FROM tickets WHERE hash = ?`, hash).Scan(&exp); err != nil {
		return "", "", time.Time{}, fmt.Errorf("read ticket: %w", err)
	}
	return ticket, hash, exp, nil
}

// Send stores an event in cg_events (local-mode event sink).
func (s *localStore) Send(ctx context.Context, e Event) (bool, error) {
	var payload any
	if len(e.Payload) > 0 {
		payload = string(e.Payload)
	}
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO cg_events (server_id, account_id, type, payload, created_at) VALUES (?, ?, ?, ?, ?)`,
		e.ServerID, e.AccountID, e.Type, payload, e.At.UTC())
	if err != nil {
		return true, fmt.Errorf("insert event: %w", err)
	}
	return false, nil
}

// Housekeep purges old tickets (local mode) and resolved auth requests (when
// the SQL transport is on) so the tables do not grow forever.
func (s *localStore) Housekeep(ctx context.Context, every time.Duration, purgeTickets, sqlTransport bool) {
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		hctx, cancel := context.WithTimeout(ctx, 30*time.Second)
		if purgeTickets {
			if res, err := s.db.ExecContext(hctx,
				`DELETE FROM tickets WHERE exp < NOW() - INTERVAL 1 DAY LIMIT 5000`); err != nil {
				s.log.Warn("housekeeping tickets failed", "err", err.Error())
			} else if n, _ := res.RowsAffected(); n > 0 {
				s.log.Info("housekeeping", "table", "tickets", "deleted", n)
			}
		}
		if sqlTransport {
			if res, err := s.db.ExecContext(hctx,
				`DELETE FROM cg_auth_requests WHERE created_at < NOW() - INTERVAL 1 HOUR LIMIT 5000`); err != nil {
				s.log.Warn("housekeeping cg_auth_requests failed", "err", err.Error())
			} else if n, _ := res.RowsAffected(); n > 0 {
				s.log.Info("housekeeping", "table", "cg_auth_requests", "deleted", n)
			}
		}
		cancel()
	}
}

// dbMonitor pings the DB in the background so /health can report it without
// doing I/O on the request path.
type dbMonitor struct {
	db *sql.DB

	mu      sync.Mutex
	ok      bool
	lastErr string
	checked time.Time
}

func newDBMonitor(db *sql.DB) *dbMonitor { return &dbMonitor{db: db} }

func (m *dbMonitor) Run(ctx context.Context, every time.Duration) {
	m.check(ctx)
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			m.check(ctx)
		}
	}
}

func (m *dbMonitor) check(ctx context.Context) {
	pctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	err := m.db.PingContext(pctx)
	m.mu.Lock()
	defer m.mu.Unlock()
	m.checked = time.Now()
	if err != nil {
		m.ok = false
		m.lastErr = err.Error()
		return
	}
	m.ok = true
	m.lastErr = ""
}

// dbStatus is the /health view of the database connection.
type dbStatus struct {
	Configured bool       `json:"configured"`
	OK         bool       `json:"ok"`
	Error      string     `json:"error,omitempty"`
	CheckedAt  *time.Time `json:"checked_at,omitempty"`
	OpenConns  int        `json:"open_conns"`
}

func (m *dbMonitor) Status() dbStatus {
	m.mu.Lock()
	defer m.mu.Unlock()
	st := dbStatus{Configured: true, OK: m.ok, Error: m.lastErr, OpenConns: m.db.Stats().OpenConnections}
	if !m.checked.IsZero() {
		t := m.checked
		st.CheckedAt = &t
	}
	return st
}
