# plugins/ — Chogan SourceMod plugins (CS:S v92, SourceMod 1.12)

SourcePawn sources for the Chogan-specific plugins (MISSION §5 probes 1–2, §6.3 auth,
§4.6 rate policy) plus the shared include and the SQL for the fallback transport.

| Path | What |
|---|---|
| `scripting/probe_setinfo.sp` | **Probe 1** — logs `GetClientInfo(client,"lt")` at every client lifecycle forward + timers; registers `cg_ticket` (fallback (b)). Never kicks. |
| `scripting/probe_ripext.sp` | **Probe 2** — async HTTPS GET via RIPExt to `https://api.github.com/zen`, `/rate_limit` and `http://127.0.0.1:8480/health`; logs status / body length / cURL error. `sm_probe_http <url>`, `sm_probe_post <url>`. |
| `scripting/chogan_auth.sp` | **Production auth** (§6.3): ticket from `setinfo lt` or `cg_ticket`, async redeem against cg-agent (RIPExt HTTP or threaded MySQL), bind account or kick; modes off/soft/hard; grace timer; reconnect cache; circuit breaker; join/leave events; natives + forwards. |
| `scripting/chogan_ratepolicy.sp` | **Rate policy** (§4.6): audits `rate`/`cl_updaterate`/`cl_cmdrate`/`cl_interp_ratio`/`cl_interp` vs `sv_*` every 30 s and on settings change, logs claimed vs *measured* packet rates (shows whether the engine clamps), optional kick after N warnings. `sm_ratepolicy`. |
| `scripting/include/chogan.inc` | Natives/forwards of `chogan_auth` for other plugins (stats, match…). |
| `sql/chogan_auth.sql` | `cg_auth_requests` + `cg_events` DDL for the SQL transport (agent DB `chogan_agent`). |
| `gamedata-v92/` | (other task) pinned v92 gamedata — see its own notes. |

**Compiler status:** these sources were written on a machine without `spcomp` (build rule:
no binaries on the workstation). They target SM 1.12 syntax (`#pragma newdecls required`,
methodmaps, enum structs) and every native/signature used was checked against the SM 1.12
includes and the RIPExt 1.3.2 includes/sources (links at the bottom). Compile them on the VM
first; a compile error there is a one-line fix, not a design problem.

---

## 1. Compile (on the VM)

SourceMod is pinned to `sourcemod-1.12.0-git7179-linux.tar.gz` (docs/decisions.md D-005); the
tarball ships the compiler at `addons/sourcemod/scripting/spcomp` (32-bit) and `spcomp64`.
RIPExt 1.3.2's zip ships its includes into the same `scripting/include/` (provision script
`server/provision/04-install-mm-sm.sh` copies `addons/sourcemod/scripting/include/ripext.inc`
+ `ripext/` into the base).

```bash
# on the VM, as a user that can read the base (or root)
SM=/opt/css/base/cstrike/addons/sourcemod/scripting
SRC=/opt/css/src/plugins/scripting          # rsync this repo's plugins/ here (e.g. scripts/rput)
OUT=/opt/css/src/plugins/compiled && mkdir -p "$OUT"

cd "$SRC"
for f in probe_setinfo probe_ripext chogan_auth chogan_ratepolicy; do
  "$SM/spcomp64" "$f.sp" -i"$SM/include" -i"$SRC/include" -o"$OUT/$f.smx" || exit 1
done
ls -la "$OUT"
```

Notes
- `-i<path>` (no space) is the form every spcomp version accepts; `$SM/include` supplies
  `sourcemod.inc` + `ripext.inc`, `$SRC/include` supplies `chogan.inc`.
- If `spcomp64` is missing use `spcomp` (needs the i386 libs that srcds already needs).
- Warnings about unused parameters are harmless; errors are not — fix, re-run.

## 2. Where the .smx go

Instances are overlayfs mounts over the shared base (`/opt/css/base/cstrike`, D-004), so a
plugin placed in the **base** `addons/sourcemod/plugins/` is seen by all seven instances; a
plugin placed in an **instance upper** dir is seen by that instance only.

| Plugin | Put it in | Why |
|---|---|---|
| `chogan_auth.smx` | base `addons/sourcemod/plugins/` | every server authenticates |
| `chogan_ratepolicy.smx` | base `addons/sourcemod/plugins/` | every server audits rates (log-only by default) |
| `probe_setinfo.smx`, `probe_ripext.smx` | base `addons/sourcemod/plugins/disabled/` | probes; load by hand on pub1 only: `sm plugins load disabled/probe_setinfo` |

The base must not change while overlays are mounted (provision scripts stop all `css@`
instances first). For a quick test without touching the base, drop the `.smx` into
`/opt/css/instances/<name>/upper/cstrike/addons/sourcemod/plugins/` (path per D-004; check
`css-overlay@<name>.service` for the exact upper dir) and `sm plugins load <name>` via RCON.

**Gamedata:** `chogan_auth` / `chogan_ratepolicy` / probes use only core natives (no SDKCall,
no offsets) — they are not affected by the §4.1 gamedata trap.

## 3. Configuration

### 3.1 `chogan_auth` — `cfg/sourcemod/chogan.cfg`

`AutoExecConfig(true, "chogan")` ⇒ SM executes **`cfg/sourcemod/chogan.cfg`** — the same file
`css-genconf` renders per instance from `server/opt/css/etc/templates/sm/chogan.cfg`
(`cg_server_id "@@INSTANCE@@"`, `cg_agent_url`, `cg_auth_mode`, `cg_auth_transport`). Cvars
missing from that file keep their defaults. If the file does not exist SM creates it with
all defaults.

| Cvar | Default | Meaning |
|---|---|---|
| `cg_auth_mode` | `1` | `0` off (nobody is checked), `1` **soft** (agent failure → cache → guest), `2` **hard** (agent failure → cache → kick). A *rejected* ticket kicks in 1 and 2. |
| `cg_agent_url` | `http://127.0.0.1:8480` | cg-agent base URL (no trailing slash). |
| `cg_server_id` | `""` (**required**) | Scope of the tickets (`pub1 pub2 dm gg awp m1 m2`). Empty ⇒ every redeem takes the api_down path (logged as error). |
| `cg_auth_timeout` | `4.0` | Seconds to wait for the agent (HTTP timeout; SQL poll deadline). No answer ⇒ api_down. |
| `cg_auth_grace` | `8.0` | Seconds after connect to present a ticket (`setinfo lt` or `cg_ticket`). Expiry: soft ⇒ guest, hard ⇒ kick. |
| `cg_auth_transport` | `ripext` | `ripext` (async HTTP) or `sql` (threaded MySQL, databases.cfg section `chogan`). If RIPExt is not loaded and a `chogan` DB config exists the plugin falls back to `sql` by itself. |
| `cg_auth_kick_msg` | `Chogan: login required - please start the game from the Chogan launcher` | Kick reason (engine appends a period; the plugin appends ` (<reason>)`). |
| `cg_auth_allow_invalid_as_guest` | `0` | `1` ⇒ invalid/used/expired/scope tickets become guests instead of kicks. |
| `cg_auth_cache_ttl` | `600` | Seconds the in-plugin `authid+ip → account` reconnect cache lives (0 disables). |
| `cg_auth_breaker_fails` | `3` | Consecutive transport failures that open the circuit breaker (0 disables). |
| `cg_auth_breaker_open` | `20.0` | Seconds the breaker stays open (agent not called, fallback immediately); then one trial request (half-open). |
| `cg_auth_events` | `1` | POST join/leave events for bound accounts (`/v1/event`, or `cg_events` in SQL mode). Fire and forget. |
| `cg_auth_debug` | `0` | Verbose log. |

Commands: `cg_ticket <token>` (client, console), `sm_cgauth` (admin: table of every client
— state, account, display name, source, guest flag, reason — plus breaker/cache/transport
health and totals), `sm_cgauth_health` (async GET `/health`), `sm_cgauth_flushcache`.

Decision table (what happens to a connecting human client):

| Situation | mode 1 soft | mode 2 hard |
|---|---|---|
| ticket ok | bound | bound |
| ticket invalid / used / expired / scope | kick (guest if `cg_auth_allow_invalid_as_guest 1`; bound if reconnect cache hits) | same |
| agent unreachable / timeout / 5xx / breaker open | cache hit ⇒ bound, else **guest** | cache hit ⇒ bound, else **kick** |
| no ticket within `cg_auth_grace` | guest | kick |
| plugin loaded late (client already in) | re-redeem `lt` once; any failure ⇒ guest, never kick | same |
| bot / SourceTV | skipped | skipped |

A guest (soft mode) who later presents `cg_ticket`, or whose agent answer arrives after the
watchdog, is upgraded to bound (`Chogan_OnAccountBound` fires then).

### 3.2 `chogan_ratepolicy` — `cfg/sourcemod/chogan_ratepolicy.cfg`

| Cvar | Default | Meaning |
|---|---|---|
| `cg_rate_enforce` | `0` | `0` log-only, `1` warn and kick after `cg_rate_warnings`. |
| `cg_rate_warnings` | `3` | Warnings before the kick. Compliance resets the counter. |
| `cg_rate_interval` | `30.0` | Periodic check interval (seconds). Settings changes are checked immediately too. |
| `cg_rate_warn_gap` | `10.0` | Min seconds between two warnings for one client. |
| `cg_rate_chat` | `1` | Tell the client in chat/console what to fix (enforce mode only). |
| `cg_rate_log_compliant` | `0` | Also log compliant clients every cycle (evidence mode). |

Policy is read live from `sv_minrate sv_maxrate sv_minupdaterate sv_maxupdaterate sv_mincmdrate
sv_maxcmdrate sv_client_min_interp_ratio sv_client_max_interp_ratio` (`0` / `-1` = no limit,
as the engine defines them). `sm_ratepolicy` prints claimed vs measured
(`GetClientAvgPackets` out/in ≈ effective update/cmd rate, `GetClientAvgData`, choke, loss,
ping) vs policy; `sm_ratepolicy reset` clears warnings. The log line on a violation includes
a heuristic note — "claim 100 > cap 66 but measured 66 pkt/s ⇒ engine clamps" vs "measured
100 ⇒ NOT clamped" — which is the §4.6 answer for docs/probes.md.

### 3.3 Probes

- `probe_setinfo`: cvar `probe_grace` (8.0). Client side: `setinfo lt hello123` **before**
  `connect`. Grep `[probe1]` in `addons/sourcemod/logs/L*.log` / console log: each line has
  `stage=… lt_ok=… lt_len=… lt="…"` and the control keys `name`/`cl_language`/`rate` so
  "no userinfo yet" is distinguishable from "lt missing". `FIRST SIGHTING of lt … at stage=…`
  is the answer. Expected on this engine (docs/source-connect-protocol.md §3): empty at
  `OnClientConnect`/`OnClientConnected`, present from `OnClientSettingsChanged#1` on. For
  fallback (b), run `cg_ticket hello123` in the client console after connecting.
- `probe_ripext`: loads, waits 2 s, fires the three GETs; grep `[probe2] RESULT`. `verdict=OK`
  (2xx/3xx) or `OK-TRANSPORT/HTTP-ERR` (4xx — TLS and the async path still worked) both
  answer probe 2 with "yes"; `verdict=FAIL error="…"` is the cURL reason (a missing
  `addons/sourcemod/configs/ripext/ca-bundle.crt` shows up here as an SSL peer certificate
  error for the https URLs but not for the agent URL).

## 4. cg-agent contract used by `chogan_auth`

From `cg-agent/types.go` / `cg-agent/server.go` in this repo:

```
POST {cg_agent_url}/v1/redeem   {"ticket","server_id","ip","authid","name"}
  200 {"ok":true,"account_id":N,"display_name":"…","phone_masked":"…","source":"api|cache|stub|local","cache_hit":b,"api_down":b}
  200 {"ok":false,"reason":"invalid|expired|used|scope|api_down","cache_hit":b,"api_down":b}
  400 malformed / missing server_id (plugin bug) · 5xx agent bug   → both treated as api_down
POST {cg_agent_url}/v1/event    {"server_id","account_id","type":"join|leave","payload":{"authid","ip","name","map","userid","source"}} → 202
GET  {cg_agent_url}/health      → 200 always, .status "ok"|"degraded"
```

`authid` is Steam2 when the client is already authorized, else the engine id string, else
`""` (SM has no auth string before `OnClientAuthorized`; `STEAM_ID_PENDING`/`STEAM_ID_LAN`/
`BOT` are sent as `""`). `account_id` is read as a 32-bit int on the plugin side
(`JSONObject.GetInt`, with `GetInt64` string fallback) — fine for phone-account ids.

SQL transport (probe 2 fallback): `sql/chogan_auth.sql` creates `cg_auth_requests` (+
`cg_events`) in the agent DB; SM reaches it through the `chogan` section of `databases.cfg`
(rendered by css-genconf from `server/opt/css/etc/templates/sm/databases.cfg`; user `css_sm`
has SELECT/INSERT/UPDATE/DELETE on `chogan_agent`, provision `05-mariadb.sh`). The agent's
SQL worker must be enabled for rows to get a verdict. The plugin INSERTs, then polls the row
by `id` every 0.5 s with `Database.Query` until `verdict IS NOT NULL` or `cg_auth_timeout`.

## 5. Design notes (why it looks like this)

- **Ticket timing.** `docs/source-connect-protocol.md` §3: the connect packet carries no
  userinfo; `CBaseClient::Connect` starts with an empty convar store, and the `setinfo` keys
  arrive in the first `net_SetConVar` after `SIGNONSTATE_CONNECTED`. So `OnClientConnected`
  only arms the grace timer and logs; the real read happens at `OnClientSettingsChanged` /
  `OnClientAuthorized` / `OnClientPutInServer` / `OnClientPostAdminCheck` — first non-empty
  wins, `g_bTicketTried` guarantees one redemption per connection.
- **Async only** (§4.4): RIPExt `HTTPRequest.Post` + callback, or `Database.Connect` /
  `Database.Query` (threaded). Nothing synchronous anywhere on the connect path.
- **Serials** (§4.5): every timer, HTTP and SQL callback carries `GetClientSerial()` and
  resolves with `GetClientFromSerial()`; a reused slot is ignored.
- **Kicks.** `KickClient()` is already queued by SourceMod to the next frame
  (core `AddDelayedKick`), so calling it from HTTP/SQL/timer callbacks is safe. When the
  decision is taken *inside* `OnClientConnected` / `OnClientSettingsChanged` / a client
  command (e.g. breaker open + hard mode), the plugin additionally defers via
  `RequestFrame` so the engine forward returns first.
- **Self-include guard.** `chogan_auth.sp` defines `CHOGAN_AUTH_IMPLEMENTATION` before
  `#include <chogan>` so the include does not declare a `SharedPlugin` dependency on itself.
- **RIPExt optional.** `#undef REQUIRE_EXTENSIONS` around `#include <ripext>` and every RIPExt
  native marked optional, so `chogan_auth` still loads (and can use SQL) on a box where
  `rip.ext` failed — that is exactly the probe-2 fallback scenario.
- **RIPExt facts relied on** (verified in the 1.3.2 sources): the callback is always invoked,
  also on transport failure (status 0, cURL message in the 3rd `error` argument); the
  callback runs on the game thread from a frame hook; `HTTPResponse.Data` throws on a
  non-JSON body (content type is checked first); header lookup is case-insensitive; the JSON
  body is serialised inside `Post()` so the `JSONObject` can be deleted right after.

## 6. Sources

- SourceMod 1.12 includes: https://github.com/alliedmodders/sourcemod/tree/1.12-dev/plugins/include
  (`clients.inc` KickClient/KickClientEx semantics, `dbi.inc` `Database.Format`, `functions.inc` `RequestFrame`)
- SourceMod core (delayed kick): https://github.com/alliedmodders/sourcemod/blob/1.12-dev/core/smn_players.cpp
- RIPExt 1.3.2 includes and sources: https://github.com/ErikMinekus/sm-ripext/tree/1.3.2
  (`pawn/scripting/include/ripext/http.inc`, `json.inc`, `http_natives.cpp`, `httprequestcontext.cpp`, `extension.cpp`)
- RIPExt release used by the provision script: https://github.com/ErikMinekus/sm-ripext/releases/tag/1.3.2
- Engine connect handshake / userinfo timing: `docs/source-connect-protocol.md` (nillerusr/source-engine mirror)
- Rate clamp report: https://github.com/ValveSoftware/Source-1-Games/issues/3812
- SM build pin: `docs/decisions.md` D-005; SM drop: https://sm.alliedmods.net/smdrop/1.12/
