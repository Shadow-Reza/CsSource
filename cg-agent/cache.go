package main

import (
	"sync"
	"time"
)

// cachedRedemption is one remembered successful redemption. It is stored twice:
//
//	"t:"+sha256(ticket)  -> reconnect with the same, already-used ticket
//	"a:"+authid+"|"+ip   -> identity fallback while the API/DB is unreachable
type cachedRedemption struct {
	Account Account
	AuthID  string
	IP      string
	Exp     time.Time
}

// Cache is a small TTL map guarded by a mutex. Expired entries are dropped
// lazily on Get and by the periodic Sweep; when full it sweeps, then evicts
// arbitrary entries (map iteration order) to make room.
type Cache struct {
	mu       sync.Mutex
	ttl      time.Duration
	capacity int
	m        map[string]cachedRedemption
	now      func() time.Time
	hits     int64
	misses   int64
}

func NewCache(ttl time.Duration, capacity int) *Cache {
	if capacity <= 0 {
		capacity = 10000
	}
	return &Cache{
		ttl:      ttl,
		capacity: capacity,
		m:        make(map[string]cachedRedemption),
		now:      time.Now,
	}
}

func keyTicket(hash string) string           { return "t:" + hash }
func keyIdentity(authid, ip string) string    { return "a:" + authid + "|" + ip }
func (c *Cache) TTL() time.Duration           { return c.ttl }

// Get returns the entry for key if present and not expired.
func (c *Cache) Get(key string) (cachedRedemption, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.m[key]
	if !ok {
		c.misses++
		return cachedRedemption{}, false
	}
	if !c.now().Before(e.Exp) {
		delete(c.m, key)
		c.misses++
		return cachedRedemption{}, false
	}
	c.hits++
	return e, true
}

// Set stores e under key with a fresh TTL.
func (c *Cache) Set(key string, e cachedRedemption) {
	c.mu.Lock()
	defer c.mu.Unlock()
	e.Exp = c.now().Add(c.ttl)
	if _, exists := c.m[key]; !exists && len(c.m) >= c.capacity {
		c.sweepLocked()
		if len(c.m) >= c.capacity {
			c.evictLocked(len(c.m) - c.capacity + 1)
		}
	}
	c.m[key] = e
}

// Sweep drops expired entries. Called periodically from main.
func (c *Cache) Sweep() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	before := len(c.m)
	c.sweepLocked()
	return before - len(c.m)
}

// Flush empties the cache and returns how many entries were removed.
func (c *Cache) Flush() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	n := len(c.m)
	c.m = make(map[string]cachedRedemption)
	return n
}

// Len is the current number of entries (including not-yet-swept expired ones).
func (c *Cache) Len() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.m)
}

// Stats returns size, hits, misses.
func (c *Cache) Stats() (int, int64, int64) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.m), c.hits, c.misses
}

func (c *Cache) sweepLocked() {
	now := c.now()
	for k, e := range c.m {
		if !now.Before(e.Exp) {
			delete(c.m, k)
		}
	}
}

func (c *Cache) evictLocked(n int) {
	for k := range c.m {
		if n <= 0 {
			return
		}
		delete(c.m, k)
		n--
	}
}
