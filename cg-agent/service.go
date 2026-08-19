package main

import (
	"context"
	"log/slog"
	"sync/atomic"
)

// Service is the mode-independent redeem logic shared by the HTTP handler and
// the SQL transport worker: cache -> backend -> cache fallback.
type Service struct {
	backend backend
	cache   *Cache
	log     *slog.Logger

	total       atomic.Int64
	okTotal     atomic.Int64
	denied      atomic.Int64
	cacheServed atomic.Int64
	apiDown     atomic.Int64
}

func NewService(b backend, c *Cache, log *slog.Logger) *Service {
	return &Service{backend: b, cache: c, log: log}
}

// Redeem never returns an error: every outcome is a RedeemResponse the plugin
// can act on. Policy (mode 0/1/2) is the plugin's job; the agent only reports
// what it knows via ok / reason / cache_hit / api_down.
func (s *Service) Redeem(ctx context.Context, req RedeemRequest) RedeemResponse {
	s.total.Add(1)
	if req.Ticket == "" {
		s.denied.Add(1)
		return RedeemResponse{Reason: ReasonInvalid}
	}
	h := hashTicket(req.Ticket)
	idKey := keyIdentity(req.AuthID, req.IP)

	// 1. Manual reconnect: the same, already-redeemed ticket from the same
	//    authid+ip within the cache TTL is fine (MISSION 6.3 reconnect case).
	if e, ok := s.cache.Get(keyTicket(h)); ok && e.AuthID == req.AuthID && e.IP == req.IP {
		s.okTotal.Add(1)
		s.cacheServed.Add(1)
		return okResponse(e.Account, SourceCache, true, false)
	}

	// 2. Ask the backend (stub / local DB / remote API).
	res, err := s.backend.Redeem(ctx, req)
	if err != nil {
		s.apiDown.Add(1)
		s.log.Warn("backend unavailable",
			"backend", s.backend.Name(),
			"err", err.Error(),
			"server_id", req.ServerID,
			"authid", req.AuthID,
			"ip", req.IP)
		// 3. Fallback: identity cache. The plugin decides guest vs kick.
		if e, ok := s.cache.Get(idKey); ok {
			s.okTotal.Add(1)
			s.cacheServed.Add(1)
			return okResponse(e.Account, SourceCache, true, true)
		}
		s.denied.Add(1)
		return RedeemResponse{Reason: ReasonAPIDown, APIDown: true}
	}
	if !res.OK {
		s.denied.Add(1)
		reason := res.Reason
		if reason == "" {
			reason = ReasonInvalid
		}
		return RedeemResponse{Reason: reason}
	}

	entry := cachedRedemption{Account: res.Account, AuthID: req.AuthID, IP: req.IP}
	s.cache.Set(keyTicket(h), entry)
	s.cache.Set(idKey, entry)
	s.okTotal.Add(1)
	return okResponse(res.Account, s.backend.Name(), false, false)
}

// redeemStatus is the /health view of the redeem counters.
type redeemStatus struct {
	Total       int64 `json:"total"`
	OK          int64 `json:"ok"`
	Denied      int64 `json:"denied"`
	CacheServed int64 `json:"cache_served"`
	APIDown     int64 `json:"api_down"`
}

func (s *Service) Status() redeemStatus {
	return redeemStatus{
		Total:       s.total.Load(),
		OK:          s.okTotal.Load(),
		Denied:      s.denied.Load(),
		CacheServed: s.cacheServed.Load(),
		APIDown:     s.apiDown.Load(),
	}
}

func okResponse(a Account, source string, cacheHit, apiDown bool) RedeemResponse {
	return RedeemResponse{
		OK:          true,
		AccountID:   a.ID,
		DisplayName: a.DisplayName,
		PhoneMasked: a.PhoneMasked,
		Source:      source,
		Guest:       false,
		CacheHit:    cacheHit,
		APIDown:     apiDown,
	}
}
