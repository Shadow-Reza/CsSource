package main

import (
	"context"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"
)

// Queue is the bounded, in-memory, asynchronous write queue for /v1/event.
// The plugin's request returns as soon as the event is enqueued; workers
// deliver it to the sink with exponential backoff and give up after
// maxAttempts (the event is then counted as dropped, never blocking the game).
// Enqueue never blocks: when the queue is full the event is dropped and the
// caller is told so.
type Queue struct {
	ch          chan Event
	sink        eventSink
	log         *slog.Logger
	workers     int
	maxAttempts int
	baseDelay   time.Duration
	maxDelay    time.Duration

	mu     sync.RWMutex
	closed bool
	wg     sync.WaitGroup

	ctxMu sync.RWMutex
	ctx   context.Context // background while running, deadline-bound while draining

	enqueued       atomic.Int64
	sent           atomic.Int64
	failedAttempts atomic.Int64
	dropped        atomic.Int64
}

func NewQueue(size, workers, maxAttempts int, baseDelay, maxDelay time.Duration, sink eventSink, log *slog.Logger) *Queue {
	if size <= 0 {
		size = 1000
	}
	if workers <= 0 {
		workers = 1
	}
	if maxAttempts <= 0 {
		maxAttempts = 1
	}
	if baseDelay <= 0 {
		baseDelay = 500 * time.Millisecond
	}
	if maxDelay < baseDelay {
		maxDelay = baseDelay
	}
	return &Queue{
		ch:          make(chan Event, size),
		sink:        sink,
		log:         log,
		workers:     workers,
		maxAttempts: maxAttempts,
		baseDelay:   baseDelay,
		maxDelay:    maxDelay,
		ctx:         context.Background(),
	}
}

// Start launches the worker goroutines.
func (q *Queue) Start() {
	for i := 0; i < q.workers; i++ {
		q.wg.Add(1)
		go q.worker()
	}
}

// Enqueue adds e without blocking. false = queue full or shut down (dropped).
func (q *Queue) Enqueue(e Event) bool {
	q.mu.RLock()
	defer q.mu.RUnlock()
	if q.closed {
		q.dropped.Add(1)
		return false
	}
	select {
	case q.ch <- e:
		q.enqueued.Add(1)
		return true
	default:
		q.dropped.Add(1)
		return false
	}
}

// Shutdown stops accepting events, gives the workers `timeout` to drain what is
// queued, then returns. Whatever is still undelivered is counted as dropped.
func (q *Queue) Shutdown(timeout time.Duration) {
	dctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	q.ctxMu.Lock()
	q.ctx = dctx
	q.ctxMu.Unlock()

	q.mu.Lock()
	if !q.closed {
		q.closed = true
		close(q.ch)
	}
	q.mu.Unlock()

	done := make(chan struct{})
	go func() {
		q.wg.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(timeout + 2*time.Second):
		q.log.Warn("queue workers did not finish in time")
	}
	q.log.Info("queue stopped",
		"sent", q.sent.Load(),
		"dropped", q.dropped.Load(),
		"failed_attempts", q.failedAttempts.Load())
}

func (q *Queue) currentCtx() context.Context {
	q.ctxMu.RLock()
	defer q.ctxMu.RUnlock()
	return q.ctx
}

func (q *Queue) worker() {
	defer q.wg.Done()
	for e := range q.ch {
		q.deliver(e)
	}
}

func (q *Queue) deliver(e Event) {
	delay := q.baseDelay
	for attempt := 1; ; attempt++ {
		ctx := q.currentCtx()
		if ctx.Err() != nil {
			q.dropped.Add(1)
			q.log.Debug("event dropped at shutdown", "type", e.Type, "server_id", e.ServerID)
			return
		}
		retryable, err := q.sink.Send(ctx, e)
		if err == nil {
			q.sent.Add(1)
			return
		}
		q.failedAttempts.Add(1)
		if !retryable || attempt >= q.maxAttempts {
			q.dropped.Add(1)
			q.log.Warn("event dropped",
				"type", e.Type,
				"server_id", e.ServerID,
				"account_id", e.AccountID,
				"attempts", attempt,
				"retryable", retryable,
				"err", err.Error())
			return
		}
		q.log.Debug("event delivery failed, will retry",
			"type", e.Type,
			"attempt", attempt,
			"next_in", delay.String(),
			"err", err.Error())
		if !sleepCtx(ctx, delay) {
			q.dropped.Add(1)
			return
		}
		delay *= 2
		if delay > q.maxDelay {
			delay = q.maxDelay
		}
	}
}

// queueStatus is the /health view of the queue.
type queueStatus struct {
	Depth          int   `json:"depth"`
	Capacity       int   `json:"capacity"`
	Workers        int   `json:"workers"`
	Enqueued       int64 `json:"enqueued"`
	Sent           int64 `json:"sent"`
	FailedAttempts int64 `json:"failed_attempts"`
	Dropped        int64 `json:"dropped"`
}

func (q *Queue) Status() queueStatus {
	return queueStatus{
		Depth:          len(q.ch),
		Capacity:       cap(q.ch),
		Workers:        q.workers,
		Enqueued:       q.enqueued.Load(),
		Sent:           q.sent.Load(),
		FailedAttempts: q.failedAttempts.Load(),
		Dropped:        q.dropped.Load(),
	}
}
