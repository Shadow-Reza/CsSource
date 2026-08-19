package main

import (
	"encoding/json"
	"time"
)

// RedeemRequest is what the SourceMod plugin POSTs to /v1/redeem. In remote
// mode the agent forwards exactly this JSON to the Chogan API.
type RedeemRequest struct {
	Ticket   string `json:"ticket"`
	ServerID string `json:"server_id"`
	IP       string `json:"ip"`
	AuthID   string `json:"authid"`
	Name     string `json:"name"`
}

// Account is what a successful redemption resolves to.
type Account struct {
	ID          int64
	DisplayName string
	PhoneMasked string
}

// RedeemResponse is the wire shape returned to the plugin by /v1/redeem and
// the shape the agent expects back from the Chogan API in remote mode.
//
//	ok:true  -> account_id, display_name, phone_masked, source, guest:false
//	ok:false -> reason (invalid|expired|used|scope|api_down)
//
// cache_hit and api_down are always present so the plugin can apply its
// mode 1 (soft) / mode 2 (hard) policy without parsing anything else.
type RedeemResponse struct {
	OK          bool   `json:"ok"`
	AccountID   int64  `json:"account_id,omitempty"`
	DisplayName string `json:"display_name,omitempty"`
	PhoneMasked string `json:"phone_masked,omitempty"`
	Source      string `json:"source,omitempty"`
	Guest       bool   `json:"guest"`
	Reason      string `json:"reason,omitempty"`
	CacheHit    bool   `json:"cache_hit"`
	APIDown     bool   `json:"api_down"`
}

// Denial reasons. The agent never invents new ones.
const (
	ReasonInvalid = "invalid"  // unknown ticket / empty ticket / malformed
	ReasonExpired = "expired"  // exp <= now
	ReasonUsed    = "used"     // used_at already set (and no cache match)
	ReasonScope   = "scope"    // issued for a different server_id
	ReasonAPIDown = "api_down" // no verdict obtainable and no cache entry
)

// Values of RedeemResponse.Source.
const (
	SourceAPI   = "api"
	SourceCache = "cache"
	SourceStub  = "stub"
	SourceLocal = "local"
)

// Event is a fire-and-forget record from a game server (POST /v1/event).
// At is stamped by the agent when the event is accepted.
type Event struct {
	ServerID  string          `json:"server_id"`
	AccountID int64           `json:"account_id"`
	Type      string          `json:"type"`
	Payload   json.RawMessage `json:"payload,omitempty"`
	At        time.Time       `json:"at"`
}
