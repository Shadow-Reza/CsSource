package main

import (
	"context"
	"log/slog"
)

// backendResult is a policy outcome from a backend. OK=false carries Reason.
type backendResult struct {
	OK      bool
	Reason  string
	Account Account
}

// backend resolves tickets. Policy outcomes (ok / invalid / expired / used /
// scope) are returned as (result, nil). A non-nil error means the backend
// itself failed (API unreachable, breaker open, DB down); the Service turns
// that into api_down and consults the cache.
type backend interface {
	// Name is the value reported as RedeemResponse.Source ("api", "local", "stub").
	Name() string
	Redeem(ctx context.Context, req RedeemRequest) (backendResult, error)
}

// eventSink receives events drained from the write queue.
// retryable=true tells the queue it may try the same event again later.
type eventSink interface {
	Send(ctx context.Context, e Event) (retryable bool, err error)
}

// stubBackend accepts any non-empty ticket (MISSION 6.3: "ship it with a stub
// mode from day one"). Account id is 1000+hash(ticket)%1000, name "Test Player".
type stubBackend struct{}

func (stubBackend) Name() string { return SourceStub }

func (stubBackend) Redeem(_ context.Context, req RedeemRequest) (backendResult, error) {
	if req.Ticket == "" {
		return backendResult{Reason: ReasonInvalid}, nil
	}
	return backendResult{OK: true, Account: Account{
		ID:          stubAccountID(req.Ticket),
		DisplayName: "Test Player",
		PhoneMasked: "+989*******00",
	}}, nil
}

// logSink writes events to the log only (stub mode).
type logSink struct{ log *slog.Logger }

func (s logSink) Send(_ context.Context, e Event) (bool, error) {
	s.log.Info("event",
		"sink", "log",
		"server_id", e.ServerID,
		"account_id", e.AccountID,
		"type", e.Type,
		"payload", string(e.Payload),
		"at", e.At)
	return false, nil
}
