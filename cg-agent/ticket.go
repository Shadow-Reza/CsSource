package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"strings"
)

// hashTicket is the only form in which a ticket is ever stored or compared:
// lowercase hex SHA-256 of the plaintext (64 chars, matches tickets.hash CHAR(64)).
func hashTicket(ticket string) string {
	sum := sha256.Sum256([]byte(ticket))
	return hex.EncodeToString(sum[:])
}

// stubAccountID maps a ticket to a deterministic test account in [1000, 1999]
// (stub mode: "account_id 1000+hash(ticket)%1000").
func stubAccountID(ticket string) int64 {
	sum := sha256.Sum256([]byte(ticket))
	return 1000 + int64(binary.BigEndian.Uint64(sum[:8])%1000)
}

// newTicket returns 32 random bytes as unpadded base64url (43 chars). Only the
// hash is stored; the plaintext is handed out exactly once.
func newTicket() (string, error) {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b[:]), nil
}

// maskPhone keeps the first 3 and last 2 digits, masks the rest, and leaves
// non-digits (like a leading '+') untouched. Numbers with 5 or fewer digits are
// fully masked. "+989121234567" -> "+989*******67".
func maskPhone(p string) string {
	p = strings.TrimSpace(p)
	digits := 0
	for _, r := range p {
		if r >= '0' && r <= '9' {
			digits++
		}
	}
	if digits == 0 {
		return p
	}
	keepHead, keepTail := 3, 2
	if digits <= 5 {
		keepHead, keepTail = 0, 0
	}
	var b strings.Builder
	seen := 0
	for _, r := range p {
		if r < '0' || r > '9' {
			b.WriteRune(r)
			continue
		}
		seen++
		if seen <= keepHead || seen > digits-keepTail {
			b.WriteRune(r)
		} else {
			b.WriteByte('*')
		}
	}
	return b.String()
}
