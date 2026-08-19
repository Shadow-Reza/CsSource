# cg-agent — Chogan auth sidecar (MISSION §6.3)

`cg-agent` is the small daemon that sits next to the seven CS:Source servers on the same
box and is **the only process that talks to the Chogan API** (`https://api.chogan.games`).
The SourceMod plugin talks to it over plain HTTP on loopback. The agent owns retries,
the cache, the write queue, the circuit breaker and `/health`.

It ships with a **stub mode** (accept any ticket, return a test account) so all seven
servers are fully working before the Chogan backend exists; **one config line** switches
it to the real API (MISSION §6.3: "Ship it with a stub mode from day one").

* Language: Go ≥ 1.22, standard library + `github.com/go-sql-driver/mysql` v1.8.1 only.
* Binary: static Linux/amd64, no CGO, no libc. Runs as the `cg-agent` system user under a
  fully sandboxed systemd unit.
* Listens on `127.0.0.1:8480`. **No authentication of its own — never expose it.**

```
SourceMod plugin ──HTTP (RIPExt)──▶ cg-agent :8480 ──HTTPS──▶ api.chogan.games   (mode = remote)
                  └─(probe-2 fallback)─▶ MariaDB cg_auth_requests ◀─poll─ cg-agent
```

---

## 1. Modes — and the one-line switch

| `mode`   | What `/v1/redeem` does | Needs |
|----------|------------------------|-------|
| `stub`   | Accepts **any non-empty** ticket. `account_id = 1000 + sha256(ticket) % 1000` (deterministic, 1000–1999), `display_name = "Test Player"`, `phone_masked = "+989*******00"`, `source = "stub"`. Empty ticket → `ok:false, reason:"invalid"`. Events are logged only. | nothing |
| `local`  | The agent owns the MariaDB tables `tickets` + `accounts` (`deploy/schema.sql`) and redeems with the exact MISSION contract: `UPDATE tickets SET used_at=NOW() WHERE hash=? AND used_at IS NULL AND exp>NOW() AND server_id=?` → then `SELECT`. `POST /v1/tickets` issues test tickets (plaintext returned once, SHA-256 stored). Events go to `cg_events`. `source = "local"`. | `[db] dsn` |
| `remote` | `POST {api.base_url}/v1/servers/redeem` with `Authorization: Bearer <token>`, same JSON shape as below. Per-attempt timeout 3 s, 1 retry on network error / 502 / 503 / 504, circuit breaker, async write queue for events. `source = "api"`. | `[api] token` |

**Switch stub → remote** (when `api.chogan.games` is live):

```toml
mode = "remote"          # was "stub"
[api]
token = "…"              # bearer token for this box
```
then `systemctl restart cg-agent`. Nothing on the game servers changes: the plugin
contract is identical in all three modes (the plugin only ever sees
`ok / reason / cache_hit / api_down`).

The redeem logic is identical in every mode (`service.go`): **cache → backend → cache
fallback**. Only the "backend" differs.

---

## 2. HTTP contract (what the plugin codes against)

All bodies are JSON. **The agent never answers 5xx for a policy outcome**: a bad ticket,
an expired ticket, even "API unreachable" are all `200` with `ok:false`. `400` only for
malformed JSON / missing `server_id` (a plugin bug), `405` wrong method, `500` only for an
agent bug (panic). The plugin should treat a connection error or non-200 exactly like
`{ok:false, reason:"api_down", api_down:true}`.

### `POST /v1/redeem`

Request (what the plugin reads in `OnClientConnected`):
```json
{"ticket":"<setinfo lt value>","server_id":"pub1","ip":"1.2.3.4","authid":"STEAM_0:1:123","name":"Player"}
```
* `ticket` — the value of the client's `setinfo lt …` (may be empty → `invalid`).
* `server_id` — this instance's id: `pub1 pub2 dm gg awp m1 m2` (cvar `cg_server_id`).
  Tickets are scoped to one server_id. **Required.**
* `ip`, `authid`, `name` — used for the identity cache and the log; `authid` is not trusted
  for anything (MISSION §3: non-Steam SteamIDs are forgeable).

Response, always `200`:
```json
{"ok":true,"account_id":1337,"display_name":"Neo","phone_masked":"+989*******67","source":"api","cache_hit":false,"api_down":false}
{"ok":false,"reason":"used","cache_hit":false,"api_down":false}
{"ok":false,"reason":"api_down","cache_hit":false,"api_down":true}
```

| field | type | meaning |
|---|---|---|
| `ok` | bool | bind the account (`true`) or apply the deny policy (`false`) |
| `account_id` | int64 | the phone account — **this is the identity** (bans, admin, stats key on it, never on SteamID) |
| `display_name` | string | |
| `phone_masked` | string | e.g. `+989*******67`; the agent never returns the full phone number |
| `source` | `api` \| `cache` \| `stub` \| `local` | where the verdict came from |
| `reason` | `invalid` \| `expired` \| `used` \| `scope` \| `api_down` | only when `ok:false`. `invalid` = unknown/empty ticket, `expired` = TTL passed, `used` = already redeemed (and not a cached reconnect), `scope` = issued for another server_id, `api_down` = no verdict obtainable (backend unreachable / breaker open / DB down) **and** no cache entry |
| `cache_hit` | bool | always present. `true` = served from the agent's cache |
| `api_down` | bool | always present. `true` = the backend could not be reached for this request (the verdict, if any, came from the cache) |

Suggested mapping to the plugin's cvar policy (MISSION §6.3, `cg_auth_mode`; the policy
itself lives in the plugin, the agent only reports facts):

| agent answer | mode 0 off | mode 1 soft (default) | mode 2 hard |
|---|---|---|---|
| `ok:true` (any source) | bind | bind | bind |
| `ok:false, reason != api_down` (`invalid/expired/used/scope`, or any unknown reason passed through from the API) | ignore | kick (a definitive "no" from the backend; the plugin may choose guest during rollout) | kick |
| `ok:false, reason = api_down` / agent unreachable / non-200 | ignore | **let in as guest** | kick |

(`ok:true, source:"cache", api_down:true` is the "fall back to cache" case of both mode 1
and mode 2 — the agent already did the fallback; the plugin just binds.)

### Cache semantics (the reconnect case)

On every `ok:true` the agent caches the result under two keys for `cache.ttl_sec`
(default 600 s = MISSION's "~10 minutes"):

1. `sha256(ticket)` → account + authid + ip. A **manual reconnect presents the same,
   already-redeemed ticket**; if `authid` **and** `ip` match the cached entry the agent
   answers `ok:true, source:"cache", cache_hit:true` without asking the backend (which would
   say `used` and kick an innocent player). Same ticket from a different ip/authid goes to
   the backend normally.
2. `authid+ip` → account. Used **only when the backend fails** (`api_down`): a known
   identity is served from cache (`ok:true, source:"cache", cache_hit:true, api_down:true`);
   an unknown one gets `ok:false, reason:"api_down"`.

The cache is in memory: a restart of `cg-agent` empties it (`/v1/cache/flush` too).

### `POST /v1/event` — fire and forget

```json
{"server_id":"pub1","account_id":1337,"type":"connect","payload":{"map":"de_dust2"}}
```
* `server_id`, `type` required; `payload` any JSON ≤ 16 KiB (optional); `account_id` may be 0.
* `202 {"queued":true}` — accepted into the bounded async queue; delivered by a worker with
  exponential backoff (`queue.*`), to the API (`remote`), to `cg_events` (`local`) or to the
  log (`stub`).
* `200 {"queued":false,"reason":"queue_full"}` — dropped (the plugin must not care).
The call returns immediately; it never waits for the API.

### `GET /health` — always `200`

```json
{"status":"ok","version":"…","mode":"stub","listen":"127.0.0.1:8480","started_at":"…","uptime_sec":42,
 "breaker":{"state":"closed|open|half_open|disabled","failures_in_window":0,"threshold":5,"window_sec":30,"probe_interval_sec":10,"opens_total":0,"rejected_total":0},
 "cache":{"size":12,"ttl_sec":600,"hits":3,"misses":9},
 "queue":{"depth":0,"capacity":10000,"workers":1,"enqueued":5,"sent":5,"failed_attempts":0,"dropped":0},
 "db":{"configured":false,"ok":false,"open_conns":0},
 "sql_transport":{"enabled":false,"processed":0,"errors":0},
 "redeem":{"total":9,"ok":8,"denied":1,"cache_served":2,"api_down":0},
 "degraded_reasons":["breaker open","db unreachable"]}
```
`status` is `ok` or `degraded` (breaker not closed, DB unreachable). It stays HTTP 200 on
purpose: a watchdog that restarts the agent when the API is down would throw away the cache
that is keeping players in. Restart only when `/health` does not answer at all.

### `POST /v1/tickets` — issue a test ticket (local / stub)

```json
→ {"account_id":1001,"server_id":"pub1","ttl_sec":90}
← {"ticket":"<43 chars base64url>","hash":"<sha256 hex>","account_id":1001,"server_id":"pub1","expires_at":"…"}
```
`local`: inserts the hash into `tickets` (exp by the DB clock). `stub`: returns a random
ticket (any ticket works in stub mode anyway; `account_id` in the reply is the one stub will
derive from it). `remote`: `404` — tickets come from the Chogan API / launcher.

### `GET /v1/cache?authid=…&ip=…` → `{"hit":false}` | `{"hit":true,"account_id":…,"display_name":…,"phone_masked":…,"expires_at":…}`
### `POST|DELETE /v1/cache/flush` → `{"flushed":n}`

### curl examples

```bash
curl -s 127.0.0.1:8480/health | jq .
curl -s -XPOST 127.0.0.1:8480/v1/redeem -d '{"ticket":"abc","server_id":"pub1","ip":"1.2.3.4","authid":"STEAM_0:1:1","name":"p"}'
#  stub: {"ok":true,"account_id":1xxx,"display_name":"Test Player","phone_masked":"+989*******00","source":"stub","cache_hit":false,"api_down":false}
curl -s -XPOST 127.0.0.1:8480/v1/redeem -d '{"ticket":"abc","server_id":"pub1","ip":"1.2.3.4","authid":"STEAM_0:1:1","name":"p"}'
#  same ticket, same authid+ip again = manual reconnect: ... "source":"cache","cache_hit":true ...
curl -s -XPOST 127.0.0.1:8480/v1/redeem -d '{"ticket":"","server_id":"pub1"}'
#  {"ok":false,"reason":"invalid","cache_hit":false,"api_down":false}
curl -s -XPOST 127.0.0.1:8480/v1/event -d '{"server_id":"pub1","account_id":1001,"type":"connect","payload":{"map":"de_dust2"}}'
#  {"queued":true}
# local mode round trip:
T=$(curl -s -XPOST 127.0.0.1:8480/v1/tickets -d '{"account_id":1001,"server_id":"pub1","ttl_sec":90}' | jq -r .ticket)
curl -s -XPOST 127.0.0.1:8480/v1/redeem -d "{\"ticket\":\"$T\",\"server_id\":\"pub1\",\"ip\":\"1.2.3.4\",\"authid\":\"STEAM_0:1:1\"}"   # ok, source local
curl -s -XPOST 127.0.0.1:8480/v1/redeem -d "{\"ticket\":\"$T\",\"server_id\":\"dm\",\"ip\":\"9.9.9.9\",\"authid\":\"STEAM_0:1:2\"}"     # ok:false reason scope
curl -s 127.0.0.1:8480/v1/cache?authid=STEAM_0:1:1\&ip=1.2.3.4
```

---

## 3. Remote mode internals (`remote.go`, `breaker.go`, `queue.go`)

* **Outbound request** = the same JSON the plugin sent, to `POST {base_url}{redeem_path}`
  (`/v1/servers/redeem`), headers `Authorization: Bearer <token>`, `Content-Type: application/json`,
  `User-Agent: cg-agent/<version>`. The API is expected to answer `200` with exactly the
  response shape above (`ok`, `account_id`, `display_name`, `phone_masked`, or `ok:false` +
  `reason`). A `200` body with neither `ok:true` nor a `reason` is treated as an API error.
  Events go to `POST {base_url}{event_path}` (`/v1/servers/events`, body = the event + `at`
  timestamp). **The event path is an assumption** — the Chogan backend did not exist when
  this was written; both paths are config keys.
* **Timeouts / retry**: `api.timeout_sec` (3 s) per attempt (dial, TLS and total);
  `api.retries` (1) extra attempt after 100 ms on a network error or 502/503/504. Never on
  4xx or 500. Worst case for one redeem = `(retries+1) × timeout + 0.5 s` = 6.5 s — the
  plugin's own HTTP timeout should be above that (or it will count a slow answer as
  `api_down`, which is also fine).
* **Circuit breaker**: closed → open after `breaker.failures` (5) failures within
  `breaker.window_sec` (30 s); while open every call is rejected **without I/O** (instant
  `api_down` → cache fallback, join rate does not collapse); every
  `breaker.probe_interval_sec` (10 s) one probe goes through (half-open); success closes,
  failure re-opens. A policy denial (`4xx`, `ok:false`) is *not* a failure — only transport
  errors, timeouts and 5xx are. `failures = 0` disables it. State in `/health.breaker`.
* **Write queue**: bounded channel (`queue.size`), `queue.workers` goroutines, per-event
  retry with exponential backoff from `retry_base_ms` to `retry_max_ms`, at most
  `max_attempts` (5). `Enqueue` never blocks; full queue = drop + counter. On SIGTERM the
  queue gets `shutdown_timeout_sec` to drain.

## 4. Local mode internals (`store_local.go`)

`UPDATE tickets SET used_at=NOW() WHERE hash=? AND used_at IS NULL AND exp>NOW() AND server_id=?`
— one row affected ⇒ `SELECT account_id, phone, display_name` (joined with `accounts`,
phone masked to `+989*******67`). Zero rows ⇒ a diagnostic `SELECT` explains why:
no row → `invalid`; `server_id` differs → `scope`; `used_at` set → `used`; `exp <= NOW()` →
`expired`. All clocks are the DB's `NOW()`. Expired tickets older than a day are purged
hourly. The DB pool is lazy: a DB that is down only shows in `/health.db` (and every
redeem becomes `api_down` → cache fallback) — the agent never refuses to start because of it.

## 5. SQL transport (MISSION probe-2 fallback, `sqltransport.go`)

If RIPExt cannot do async HTTPS on SM 1.12 / CS:S v92, the plugin uses SourceMod's threaded
MySQL instead (`Database.Query`, SourceMod docs:
https://sm.alliedmods.net/new-api/dbi/Database). Set `[sql_transport] enabled = true`
(needs `[db] dsn`; `mode` can still be `stub`, `local` or `remote` — the transport only
changes how requests reach the same `Service.Redeem`).

```
plugin:  INSERT INTO cg_auth_requests (ticket, server_id, ip, authid, name) VALUES (?,?,?,?,?)
         -> remember the insert id (SQL_GetInsertId / results.InsertId)
agent:   every poll_ms (250): SELECT … WHERE verdict IS NULL ORDER BY id LIMIT batch
         -> Service.Redeem -> UPDATE … SET verdict='ok'|'fail', account_id, display_name,
            phone_masked, source, reason, cache_hit, api_down, ticket='', resolved_at=NOW()
            WHERE id=? AND verdict IS NULL
plugin:  poll SELECT verdict, account_id, display_name, phone_masked, source, reason, cache_hit, api_down
         FROM cg_auth_requests WHERE id=?  every ~250 ms until verdict IS NOT NULL;
         no verdict after ~10 s => treat as api_down (agent down).
```
Rows older than one hour are purged by the agent. `css_sm` has SELECT/INSERT/UPDATE/DELETE
on the `chogan_agent` database for this (`server/provision/05-mariadb.sh`).

---

## 6. Configuration — `/etc/cg-agent/config.toml`

Full annotated example with every key and default: `deploy/config.example.toml`.
Secrets (`api.token`, `db.dsn`) live in this file: **`chown cg-agent:cg-agent; chmod 0600`**.
The agent refuses to start if the file is world-readable and contains a secret, and warns
if it is group-readable. Environment overrides (handy for tests): `CG_AGENT_MODE`,
`CG_AGENT_LISTEN`, `CG_AGENT_API_TOKEN`, `CG_AGENT_DB_DSN`. `cg-agent -check` validates and exits.

| key | default | notes |
|---|---|---|
| `mode` | `stub` | `stub` \| `local` \| `remote` |
| `listen` | `127.0.0.1:8480` | warns if not loopback |
| `log_level` | `info` | `debug` \| `info` \| `warn` \| `error` |
| `shutdown_timeout_sec` | `5` | graceful stop budget |
| `cache.ttl_sec` | `600` | identity / ticket cache TTL |
| `cache.max_entries` | `50000` | |
| `api.base_url` | `https://api.chogan.games` | |
| `api.token` | `""` | bearer token (secret) |
| `api.timeout_sec` | `3` | per attempt |
| `api.retries` | `1` | extra attempts on network error / 502 / 503 / 504 |
| `api.redeem_path` | `/v1/servers/redeem` | |
| `api.event_path` | `/v1/servers/events` | assumed, not confirmed |
| `api.insecure_skip_verify` | `false` | |
| `breaker.failures` | `5` | `0` disables |
| `breaker.window_sec` | `30` | |
| `breaker.probe_interval_sec` | `10` | |
| `queue.size` | `10000` | |
| `queue.workers` | `1` | |
| `queue.max_attempts` | `5` | |
| `queue.retry_base_ms` / `queue.retry_max_ms` | `500` / `30000` | |
| `db.dsn` | `""` | go-sql-driver DSN, e.g. `cg_agent:PW@tcp(127.0.0.1:3306)/chogan_agent` (https://github.com/go-sql-driver/mysql#dsn-data-source-name); `parseTime=true` and 3/5/5 s timeouts are added automatically |
| `db.max_open` / `db.max_idle` | `8` / `4` | |
| `sql_transport.enabled` (or top-level `sql_transport`) | `false` | |
| `sql_transport.poll_ms` | `250` | min 50 |
| `sql_transport.batch` | `50` | |
| `tickets.default_ttl_sec` | `90` | `POST /v1/tickets` default |

### Config file format (TOML subset)

The parser (`config.go: parseTOML`) is ~150 lines of standard library and supports exactly:

* `# comment` to end of line (outside strings), blank lines, CRLF or LF
* `[section]` headers (one level; keys inside become `section.key`)
* `key = value` with key chars `[A-Za-z0-9_.-]`
* values: `"basic string"` (escapes `\" \\ \n \t \r`), `'literal string'` (no escapes),
  integers (`_` separators allowed, e.g. `10_000`), floats, `true` / `false`
* duplicate keys are an error; unknown keys are a warning; a wrong type is an error

Not supported (error): arrays, inline tables, multi-line strings, dates, quoted or dotted
keys, `[[array of tables]]`. Real TOML files that stick to the above parse identically with a
full TOML parser, so the file can be moved to one later without changes.

---

## 7. Build, test, deploy

```bash
cd cg-agent
go mod tidy                        # once, fetches github.com/go-sql-driver/mysql v1.8.1 (+ filippo.io/edwards25519)
make test                          # unit tests: hashing, TOML, config, breaker, cache, service, remote (httptest), queue, HTTP. No DB, no network.
make                               # CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags '-s -w -X main.version=…' -o bin/cg-agent .
sudo ./deploy/install.sh           # on the VM: user cg-agent, /usr/local/bin/cg-agent, /etc/cg-agent/config.toml (0600), unit, start
mysql --protocol=socket -uroot chogan_agent < deploy/schema.sql   # only for mode=local / sql_transport
journalctl -u cg-agent -o cat -f | jq .                           # JSON logs
```

`deploy/cg-agent.service`: `User=Group=cg-agent`, `Restart=always`, `RestartSec=2`,
`StartLimitIntervalSec=0` (never stop retrying — the servers fail open meanwhile),
`ExecStartPre=cg-agent -check`, `ProtectSystem=strict` with **no** writable paths,
`PrivateTmp`, `NoNewPrivileges`, `ProtectHome`, `ReadOnlyPaths=/etc/cg-agent`,
`MemoryDenyWriteExecute`, `SystemCallFilter=@system-service`, `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX`,
`CapabilityBoundingSet=` empty, `MemoryMax=256M`. Directive reference:
https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html

Logs are JSON lines on stdout (Go `log/slog`), one object per event, e.g.
`{"time":…,"level":"INFO","msg":"redeem","app":"cg-agent","server_id":"pub1","authid":…,"ip":…,"ok":true,"source":"stub","account_id":1337,"cache_hit":false,"api_down":false,"ms":0}`.
SIGTERM/SIGINT: stop listening, finish in-flight redeems, drain the event queue
(`shutdown_timeout_sec`), exit 0.

### Induced-failure test (MISSION §7 item 5)

`systemctl stop cg-agent` (or `kill -9`) while players are on: the plugin's requests fail to
connect → it applies mode 1 (guest) / mode 2 (kick) — the game server neither freezes (all
calls are async) nor empties in mode 1. `systemctl start cg-agent` → `/health` is back within
a second (the cache is empty after a restart, so for the next 10 minutes an API outage cannot
be bridged from cache; that is the accepted trade-off of an in-memory cache).

---

## 8. File map

| file | purpose |
|---|---|
| `main.go` | flags (`-config`, `-check`, `-version`), JSON logger, wiring, signals, graceful shutdown |
| `server.go` | HTTP handlers: `/health`, `/v1/redeem`, `/v1/event`, `/v1/tickets`, `/v1/cache`, `/v1/cache/flush` |
| `service.go` | mode-independent redeem: cache → backend → cache fallback; counters |
| `backend.go` | `backend` / `eventSink` interfaces, stub backend, log sink |
| `store_local.go` | MariaDB pool, local backend (atomic UPDATE), ticket issuing, `cg_events` sink, housekeeping, DB monitor |
| `remote.go` | HTTPS client for the Chogan API, retry, breaker accounting |
| `breaker.go` | circuit breaker (closed / open / half-open) |
| `cache.go` | TTL cache with capacity |
| `queue.go` | bounded async write queue with backoff |
| `sqltransport.go` | `cg_auth_requests` poller (probe-2 fallback) |
| `ticket.go` | `hashTicket` (SHA-256 hex), `stubAccountID`, `newTicket` (32 random bytes, base64url), `maskPhone` |
| `config.go` | `Config`, validation, permission check, TOML-subset parser |
| `types.go` | wire types, reason/source constants |
| `agent_test.go` | unit tests (no DB, no network) |
| `deploy/cg-agent.service`, `deploy/config.example.toml`, `deploy/schema.sql`, `deploy/install.sh` | deployment |
| `Makefile`, `go.mod`, `go.sum` | build |

## 9. Known limitations / open points

* Cache is per-process memory; a restart forgets it (no disk state by design — the unit
  has no writable path).
* `api.event_path` and the event body are an assumption until the Chogan API spec exists.
* The agent trusts the plugin completely (no auth on loopback). Anything on the box that can
  reach `127.0.0.1:8480` can redeem tickets or flush the cache — acceptable on a single-
  purpose VM, and why `listen` must stay on loopback.
* Not verified on real hardware by the author of this directory: the code was written
  without a Go toolchain at hand; the orchestrator builds/tests it on Linux (`make test`).
