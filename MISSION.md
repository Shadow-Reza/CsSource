# MISSION — Chogan Counter-Strike: Source server network

You are building the complete server-side of a closed CS:Source gaming platform,
end to end, in one run. This file is the spec. Commit it and re-read it whenever
you are about to make a decision.

**Write in English in the repo. Report to the operator in Persian.**

---

## 1. End state

Seven Counter-Strike: **Source v92** servers on one Ubuntu 24.04 VM, all reachable,
all supervised by systemd, all sharing one base install, all fronted by an
account system where players log in with a **phone number** through the Chogan
launcher.

**All seven bind to a single IP: `212.80.8.87`.** Pass `+ip 212.80.8.87` to every
instance — do not let them bind `0.0.0.0`.

| # | Server | Slots | tickrate | `-port` | `+clientport` | `-steamport` |
|---|---|---|---|---|---|---|
| 1 | Public #1 | 32 | 66 | 27017 | 27007 | 26902 |
| 2 | Public #2 | 32 | 66 | 27018 | 27008 | 26903 |
| 3 | DeathMatch | 24 | 66 | 27019 | 27009 | 26904 |
| 4 | GunGame | 24 | 66 | 27025 | 27010 | 26905 |
| 5 | AimAwp | 20 | 100 | 27026 | 27011 | 26906 |
| 6 | Match #1 | 12 | 100 | 27015 | 27005 | 26900 |
| 7 | Match #2 | 12 | 100 | 27016 | 27006 | 26901 |

`+clientport` and `-steamport` **must** be unique per instance or the instances
fight over Steam sockets. This is the single most common multi-instance failure —
and it is sharper here because everything is on one IP, so nothing else separates
them. Use `-strictportbind` so a collision fails loudly instead of silently
walking to the next free port.

Plus: a `cg-agent` auth sidecar, MariaDB, nginx FastDL, an anti-cheat layer,
firewalling, monitoring, and a repo that a future session can pick up cold.

---

## 2. Rules

1. **Build in dependency order, and probe before you commit to a design.** §5 lists
   four unknowns. Each one has a fallback. Run the probe, take the branch, record
   which branch you took and why. Do not build on an assumption you have not tested.
2. **One Public server fully working before you replicate.** Every mistake you make
   before that point gets copied six times.
3. **Never disable SSH password login.** Add your key; leave password auth alone.
   This is the server owner's explicit rule.
4. **Evidence, not claims.** Every assertion in your final report needs raw command
   output behind it. "The server is running" is not evidence; `systemctl status`
   plus a successful client connection is.
5. **Commit as you go**, into `docs/`: decisions, errors and how you solved them,
   exact versions and build IDs, and anything you discovered that contradicts this
   file. Future sessions read only what you commit.
6. **If something here turns out to be wrong, say so loudly in the report.** This
   spec is researched but not infallible. A contradiction you found is more
   valuable than a task you completed.
7. Open a PR. **Do not merge.**

---

## 2b. Autonomy — read this twice

**This is a single long autonomous run. The operator is not watching and cannot
answer you. Do not stop.**

- **Never halt to ask a question.** If you hit a decision you would normally raise,
  pick the option this spec points at (or the most conservative reversible one),
  write it to `docs/OPEN-QUESTIONS.md` with your reasoning and what you would want
  confirmed, and keep going. A run that stops at hour one and waits has failed even
  if everything it did was correct.
- **Never wait for approval.** There is no approval gate anywhere in this mission
  except the final PR, which you open and leave unmerged.
- **When something is genuinely blocked, park it and move on.** Note it, switch to
  the next independent piece of work, and come back later with fresh context. Do
  not burn the run grinding on one wall. Most of §6 is parallelisable once §6.1 and
  §6.2 exist.
- **Every probe in §5 has a fallback and none of them is a stop.** Take the branch,
  log it, continue.
- **Work the priority order in §5b.** If you run out of budget, what matters is
  which things are finished, not how far down the list you got.
- Commit continuously so that if the run ends abruptly, nothing is lost and the
  next session can resume from the repo alone.

---

## 3. Verified facts — do not re-research these

All of this was verified against primary sources on 2026-08-18 and then
adversarially re-verified. Trust it; spend your time building.

### Getting the server files
CS:S v92 is the 2 July 2021 build. **Valve still distributes it** on a public,
password-free beta branch. App `232330` is `freetodownload`, so anonymous works:

```bash
steamcmd +force_install_dir /opt/css/base \
         +login anonymous \
         +app_update 232330 -beta previous_build validate \
         +quit
```
Expect buildid **6953255**. Verify it and record it. `+force_install_dir` must come
**before** `+login` or it is silently ignored.

Do **not** use a community repack. This first-party path is the whole reason v92
was chosen over v34.

### Stack
- Metamod:Source **1.11 or 1.12**, stock upstream.
- SourceMod **1.12**, stock upstream. No community patches — they are not needed on v92.
- RevEmu (bir3yk fork) for non-Steam auth, with a **June 2021 or newer**
  `steamclient.so` renamed to `steamclient_valve.so`.
- SMAC from **`srcdslab/sm-plugin-SMAC`** — this specific fork, not the legacy one.
  Only srcdslab does engine detection correctly.
- Lilac from `srcdslab/sm-plugin-lilac`.
- RIPExt (`ErikMinekus/sm-ripext`) for async HTTPS from SourcePawn.
- YaPB is CS 1.6 — irrelevant here. CS:S has Valve's built-in bots (`bot_quota`).

### Source engine facts that shape the design
- `setinfo` exists on Source and each userinfo **key and value is capped at 260
  bytes independently**, up to 255 keys, sent over the reliable netchannel. Unlike
  GoldSrc's 255-byte total, **a JWT fits**. Key names must be `[A-Za-z0-9_]` only.
- The launcher must run `setinfo` **before** `connect`. Keys created after connect
  are silently ignored.
- Read the token in `OnClientConnected` via `GetClientInfo()`. Kick with
  `KickClient()` from the async callback.
- Non-Steam SteamIDs are forgeable on every build. **Never key identity, bans or
  admin on SteamID.** The phone account is the identity.

---

## 4. Traps — each of these has cost someone days

**4.1 The gamedata trap. This one crashes the server.**
SourceMod commit `5d468dd2` (2025-02-20) updated CS:S gamedata for v93 and shifted
every vtable index (Linux `GiveNamedItem` 402→409, `Teleport` 109→111, …). It
deleted `core.games/engine.css.txt` and `sdkhooks.games/game.cstrike.txt` and
merged CS:S into orangebox_valve. **Current upstream gamedata is wrong for v92.**

Fix:
- Take those files from the commit's **parent** (`5d468dd2^`) and place them in
  `addons/sourcemod/gamedata/custom/` — that directory is parsed after the main
  files and is never overwritten.
- Set `"DisableAutoUpdate" "yes"` in `addons/sourcemod/configs/core.cfg` **and**
  pass `-noupdate`. Without this the updater re-pulls the v93 files and you crash
  on map change.
- Note `sdktools.games/engine.css.txt` was *not* deleted and still ships — pin only
  the two that were.

**4.2 RevEmu segfault.** When v92 shipped, servers segfaulted immediately after
`Loaded local 'steamclient.so' OK`. Cause: a stale `steamclient.so`. Fix: use the
13 June 2021 or newer one. If you see this crash, do not go hunting in your own
code.

**4.3 Silent admin failure.** Set `"SteamAuthstringValidation" "no"` in `core.cfg`.
On non-Steam there is no Steam backend to validate against, and leaving the default
breaks all admin access with no error. Authenticate admins by name+password or IP.

**4.4 Blocking I/O kills the server.** srcds is single-threaded for the game
simulation. Any synchronous HTTP or SQL call inside a `client_*` forward freezes
every player. Use RIPExt's async API or SourceMod's threaded MySQL (`SQL_TQuery` /
`Database.Query`) — never the synchronous variants on a hot path.

**4.5 Client index across an async boundary.** The slot can be reused before your
callback fires, and you will bind one player's account to another. Always capture
`GetClientSerial()` and resolve with `GetClientFromSerial()`.

**4.6 Rate clamps may not work.** `Source-1-Games` issue #3812 reports CS:S
server-side rate clamps are not enforced. Status on v92 is unknown. Set them, then
**verify with `status` and `net_graph`** whether they actually bind. If they do not,
enforce with a plugin that kicks out-of-policy clients, and report it.

---

## 5. Probe first — four unknowns, each with a branch

Do these **before** building the thing that depends on them. Record the answer and
the branch you took in `docs/probes.md`.

| # | Probe | If it works | If it fails |
|---|---|---|---|
| 1 | On a client, `setinfo lt hello`, connect, and read `GetClientInfo(client,"lt",…)` in `OnClientConnected` | Token-in-setinfo is the auth channel. Build §6.3 as specified. | **Do not stop.** Try, in order: (a) the connect `password` field read via a pre-connect hook, (b) a client console command registered with `RegConsoleCmd` that the launcher fires immediately after connect, with a short grace timer before kicking. Implement whichever works, build §6.3 on it, and flag it prominently in the report and in `OPEN-QUESTIONS.md`. |
| 2 | Does RIPExt load on SM 1.12 and complete an async HTTPS request? | Use it for the plugin↔sidecar call. | Fall back to SourceMod threaded MySQL as the transport: plugin INSERTs an auth request row, sidecar writes the verdict, plugin reads it back async. Slower, but robust and needs no extra binary. |
| 3 | Does `smac_wallhack` from srcdslab load and activate, including the CS:S FarESP radar module? | Tune `smac_wallhack_maxtraces` and keep it. | Do not stop. Record the exact failure, try the legacy SMAC fork as a second attempt, and continue the build without it. Flag it at the top of the report — this was a primary reason v92 was chosen over v34, so a negative result is high-value information, not a blocker. |
| 4 | Load test: fill servers with bots, sample **server FPS ten times** (it is instantaneous and noisy), measure CPU and RSS per instance, **with and without the anti-cheat wallhack module** | Report how many instances at what tickrate and slot count this hardware actually carries. | — |

On probe 4: previous advice said 6 cores would not be enough. That was an opinion,
not a measurement, and Valve's own documentation points the other way. **Your
numbers decide, not that claim.** If 6 cores are tight, say what to cut or add.

### 5b. Priority order

If the run ends early, this is the order that leaves the most value on disk. Finish
each before starting the next.

1. §6.1 base + §6.2 one Public server actually accepting connections
2. §5 probes 1-3 answered and recorded
3. §6.7 hardening (firewall, RCON, A2S) — a reachable unhardened server on a public
   IP is worse than no server
4. §6.3 auth in stub mode
5. §6.4 anti-cheat, log-only
6. §6.5 replicate to five servers
7. §5 probe 4, the load test
8. §6.6 the two Match servers — **the correct thing to drop if time runs out**

---

## 6. Build

### 6.1 Base
Ubuntu 24.04. One nologin system user per instance. Full systemd sandboxing
(`NoNewPrivileges`, `PrivateTmp`, `ProtectSystem=strict`, `ProtectHome`, scoped
`ReadWritePaths`), plus `CPUAccounting` and `MemoryAccounting` so you can measure
per instance.

srcds is 32-bit: `dpkg --add-architecture i386` then `lib32gcc-s1 lib32stdc++6
libc6:i386 libncurses6:i386 libtinfo6:i386 libcurl4:i386`. Note `lib32gcc1` no
longer exists on 24.04 and guides saying `libncurses5:i386` are stale. If library
loading fails, rename the bundled `libgcc_s.so.1` and `libstdc++.so.6` in the
server directory so the loader picks up the system ones. `wrong ELF class:
ELFCLASS64` on a 32-bit server is normal.

Shared read-only base at `/opt/css/base` + per-instance overlayfs (cleaner than a
symlink farm). These **must** stay per-instance and writable: `cfg/`, `logs/`,
`downloads/`, `addons/sourcemod/{configs,logs,data,plugins}`,
`addons/metamod/metaplugins.ini`, `mapcycle.txt`, `banned_user.cfg`,
`banned_ip.cfg`, the SourceTV demo directory. Never share the SQLite file in
`sourcemod/data` — put everything on MariaDB instead.

systemd template unit using `srcds_run` with `-norestart` (so it does not fight
`Restart=always`), `-strictportbind` (fail loudly instead of silently walking to
the next port), `-nobreakpad`, `-insecure`, `-noupdate`.

### 6.2 First Public server, complete
Config, map rotation, Valve bots via `bot_quota`, stock SourceMod `mapchooser` /
`nominations` / `rockthevote`, MariaDB-backed stats, nginx FastDL with bzip2 files
and `limit_rate` around 1500k.

FastDL shares the single IP with the game traffic, so it cannot be isolated onto a
separate address. That makes `limit_rate` **mandatory, not optional** — an
unthrottled map-download storm at round change competes directly with the game's
own uplink and is a self-inflicted outage. Serve it on port 80 bound to
`212.80.8.87`.

Rates: `sv_minrate 80000`, `sv_maxrate 0`, `sv_minupdaterate 33`,
`sv_maxupdaterate 66`, `sv_mincmdrate 33`, `sv_maxcmdrate 66`,
`sv_client_min_interp_ratio 1`, `sv_client_max_interp_ratio 2`. Setting floor equal
to ceiling gives everyone one rate profile. Then verify per trap 4.6.

**Do not proceed past this point until a real client connects and plays.**

### 6.3 Auth — phone-number login
Two pieces.

**`cg-agent`** — a small daemon (Rust or Go) on the same box, listening on
`127.0.0.1`. It is the only thing that talks to the Chogan API over HTTPS. It owns
retries, caching, the write queue, a circuit breaker, and `/health`.

**Ship it with a stub mode from day one.** In stub mode it accepts any ticket and
returns a test account. This is deliberate: the Chogan backend
(`api.chogan.games`) is being built in parallel and is not ready. Stub mode means
all seven servers are fully working before it exists, and one config line switches
to real. Do not build anything that blocks on that backend.

**The SourceMod plugin** — reads the ticket from `setinfo lt` in
`OnClientConnected`, redeems it against the agent asynchronously, then binds the
account or calls `KickClient()`.

The redemption contract (implement the agent side to match, so the API can be
dropped in later): ticket is single-use, ~90 second TTL, scoped to one `server_id`,
stored server-side as a hash only, redeemed with an atomic
`UPDATE … SET used_at=now() WHERE hash=? AND used_at IS NULL AND exp>now() AND server_id=?`.

**Fail open, not closed.** Give it three modes via cvar: `0` off, `1` soft (on API
failure fall back to cache, else let them in as a guest), `2` hard (on failure fall
back to cache, else kick). Default to `1`. Add a circuit breaker — without one,
every connect eats a full timeout when the API is down and your join rate collapses.

Handle the reconnect case: a manual reconnect presents an already-redeemed ticket
and would kick an innocent player. Cache `authid+ip → account` for ~10 minutes.

### 6.4 Anti-cheat
SMAC (srcdslab) with `smac_wallhack` — a SetTransmit-based visibility culler plus
CS:S radar poisoning that breaks long-range ESP. Wallhack is **not detectable**
server-side on any engine; culling is the only real answer, which is why this
matters more than any detector.

Lilac alongside it. Its README says angle detection does not work on non-Steam CS:S
and names v34 and v91; v92 is untested. **Run everything log-only with autoban off
for now** and report what the logs look like. The operator will decide thresholds
from real data, not from defaults.

Measure the CPU cost of the wallhack module separately — its own cvar description
warns about it, and it is probably the largest single variable in your load test.

### 6.5 Replicate
Public #2, DeathMatch, GunGame, AimAwp from the proven template.

CS:S specifics: weapon restriction needs a plugin (unlike CS 1.6 where it is
cvar-driven). One respawn authority per server — a DM plugin and a GunGame plugin
both respawning is the classic cause of "players spawn inside each other" and round
-start crashes.

### 6.6 Match servers — the one real gap
**There is no maintained match/PUG/mix system for CS:Source in 2026.** get5,
MatchZy and csgo-pug-setup are all CS:GO or CS2. CSSMatch's repo and SourceForge
page are gone. The `srcdslab` org, which is the most active CS:S plugin ecosystem,
has no match repo at all.

This is also the **least-verified** claim in the whole spec — `forums.alliedmods.net`
returned 403 to every research attempt, and that is the likeliest place a legacy
CS:S match plugin still lives.

So: **before writing anything, search AlliedModders yourself** for "Mix Mod"
(thread 162329) and "CSSMatch". If something usable exists, use it and say so. If
not, build a minimal match plugin — ready-up, knife round, side switch, score
tracking, pause — and stream results out via `logaddress_add` to a collector rather
than calling an API from inside the plugin.

If you run short of time, **the two Match servers are the right thing to defer.**
Get the other five solid and say clearly what is left.

### 6.7 Harden
RCON on Source is TCP on the same port number as the game's UDP port. Firewall it
off the internet entirely; unique password per instance.

**Firewall A2S too**, except your monitoring IP. Players arrive only through the
launcher, which gets the server list from Chogan's own API — so nothing breaks, and
you remove the entire query-flood and scanner surface with one rule. Do this even
if v92 turns out to have Valve's A2S challenge fix.

With one IP carrying all seven game ports plus FastDL plus RCON plus SSH, the
firewall is doing more work than usual. Write the ruleset explicitly and commit it:
allow SSH from the operator, allow UDP 27015-27026 from anywhere, allow TCP 80,
allow A2S only from the monitoring IP, drop TCP on the game ports (that is RCON)
from everywhere except loopback and the operator. Add per-source-IP rate limiting
on the UDP game ports.

Add an A2S watchdog: srcds can hang while still holding its port, and systemd will
never notice. Query each instance periodically and restart after N failures.

Disk is 50 GB. Cap and rotate SourceTV demos and logs from the start, not after the
disk fills.

---

## 7. Report

`docs/FINAL-REPORT.md`, in Persian, containing:

1. Exact versions and the **server build ID** you actually got.
2. The four probe answers, with raw output, and which branch you took for each.
3. Load test numbers: per-instance CPU and RSS, server FPS sampled ten times, with
   and without the wallhack module. State plainly what this hardware carries.
4. Proof each of the seven servers runs and accepts a connection — or exactly which
   ones do not and why.
5. Proof the auth path works end to end in stub mode, **including an induced
   failure**: kill `cg-agent` mid-session and show the server neither froze nor
   emptied.
6. Every place you departed from this spec, and why.
7. Anything in this spec you found to be wrong.
8. What is not done.

Open a PR. Do not merge.
