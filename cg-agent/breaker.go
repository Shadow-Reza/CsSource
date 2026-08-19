package main

import (
	"sync"
	"time"
)

// BreakerState is the classic three-state circuit breaker state.
type BreakerState int

const (
	BreakerClosed   BreakerState = iota // normal: every call goes through
	BreakerOpen                         // tripped: calls are rejected without I/O
	BreakerHalfOpen                     // probing: one call at a time is let through
)

func (s BreakerState) String() string {
	switch s {
	case BreakerClosed:
		return "closed"
	case BreakerOpen:
		return "open"
	case BreakerHalfOpen:
		return "half_open"
	}
	return "unknown"
}

// Breaker opens after `threshold` failures within `window`, then lets one probe
// through every `probeEvery`. A probe success closes it; a probe failure keeps
// it open for another probeEvery. threshold <= 0 disables the breaker.
//
// Why: without it, every connect while the API is down eats a full timeout and
// the join rate collapses (MISSION 6.3).
type Breaker struct {
	mu         sync.Mutex
	threshold  int
	window     time.Duration
	probeEvery time.Duration
	now        func() time.Time

	state    BreakerState
	failures []time.Time // timestamps of recent failures (closed state only)
	openedAt time.Time
	probeAt  time.Time
	probing  bool
	opens    int64
	rejected int64
}

func NewBreaker(threshold int, window, probeEvery time.Duration) *Breaker {
	if window <= 0 {
		window = 30 * time.Second
	}
	if probeEvery <= 0 {
		probeEvery = 10 * time.Second
	}
	return &Breaker{
		threshold:  threshold,
		window:     window,
		probeEvery: probeEvery,
		now:        time.Now,
	}
}

// Allow reports whether a call may proceed right now. Every Allow()==true must
// be followed by exactly one Success() or Failure().
func (b *Breaker) Allow() bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.threshold <= 0 {
		return true
	}
	now := b.now()
	switch b.state {
	case BreakerClosed:
		return true
	case BreakerOpen:
		if now.Sub(b.openedAt) >= b.probeEvery {
			b.state = BreakerHalfOpen
			b.probing = true
			b.probeAt = now
			return true
		}
		b.rejected++
		return false
	default: // BreakerHalfOpen
		if b.probing && now.Sub(b.probeAt) < b.probeEvery {
			// a probe is already in flight (or was never reported); wait
			b.rejected++
			return false
		}
		b.probing = true
		b.probeAt = now
		return true
	}
}

// Success records a successful call and closes the breaker.
func (b *Breaker) Success() {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.state = BreakerClosed
	b.failures = b.failures[:0]
	b.probing = false
}

// Failure records a failed call. In closed state it may trip the breaker; in
// half-open state it re-opens it.
func (b *Breaker) Failure() {
	b.mu.Lock()
	defer b.mu.Unlock()
	now := b.now()
	switch b.state {
	case BreakerHalfOpen:
		b.tripLocked(now)
	case BreakerOpen:
		// late report from a call that was allowed before the trip: ignore
	default:
		if b.threshold <= 0 {
			return
		}
		b.failures = append(b.failures, now)
		b.pruneLocked(now)
		if len(b.failures) >= b.threshold {
			b.tripLocked(now)
		}
	}
}

// State returns the current state (for logging/tests).
func (b *Breaker) State() BreakerState {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.state
}

// BreakerStatus is the /health view of the breaker.
type BreakerStatus struct {
	State            string     `json:"state"`
	FailuresInWindow int        `json:"failures_in_window"`
	Threshold        int        `json:"threshold"`
	WindowSec        int        `json:"window_sec"`
	ProbeIntervalSec int        `json:"probe_interval_sec"`
	OpenedAt         *time.Time `json:"opened_at,omitempty"`
	OpensTotal       int64      `json:"opens_total"`
	RejectedTotal    int64      `json:"rejected_total"`
}

func (b *Breaker) Status() BreakerStatus {
	b.mu.Lock()
	defer b.mu.Unlock()
	now := b.now()
	b.pruneLocked(now)
	st := BreakerStatus{
		State:            b.state.String(),
		FailuresInWindow: len(b.failures),
		Threshold:        b.threshold,
		WindowSec:        int(b.window / time.Second),
		ProbeIntervalSec: int(b.probeEvery / time.Second),
		OpensTotal:       b.opens,
		RejectedTotal:    b.rejected,
	}
	if b.state != BreakerClosed {
		t := b.openedAt
		st.OpenedAt = &t
	}
	if b.threshold <= 0 {
		st.State = "disabled"
	}
	return st
}

func (b *Breaker) tripLocked(now time.Time) {
	b.state = BreakerOpen
	b.openedAt = now
	b.probing = false
	b.failures = b.failures[:0]
	b.opens++
}

func (b *Breaker) pruneLocked(now time.Time) {
	cut := now.Add(-b.window)
	i := 0
	for i < len(b.failures) && b.failures[i].Before(cut) {
		i++
	}
	if i > 0 {
		b.failures = append(b.failures[:0], b.failures[i:]...)
	}
}
