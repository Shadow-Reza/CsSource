# Open questions — decisions taken without the operator (MISSION §2b)

Each entry: what I found, what I decided, why, and what I would want confirmed.

## OQ-1 — VM is Ubuntu 22.04.5, spec says 24.04
- **Found:** `PRETTY_NAME="Ubuntu 22.04.5 LTS"`, kernel 5.15. Fresh box, nothing installed.
- **Decided:** build on 22.04, do **not** `do-release-upgrade`.
- **Why:** an in-place release upgrade is not reversible, takes 30+ min, and carries a
  real risk of breaking SSH on a box whose one hard rule is "never lose password SSH".
  Every component the spec needs exists on jammy: `lib32gcc-s1`, `libncurses6:i386`,
  overlayfs, systemd 249 (all sandboxing directives used), nftables 1.0.2, MariaDB 10.6,
  nginx 1.18. `lib32gcc1` is already gone on jammy too, so the spec's package list is
  the right one here as well.
- **Would confirm:** whether the operator wants a 24.04 upgrade scheduled in a
  maintenance window later (all instances must be stopped; overlay lower layer must
  not change while mounted).

## OQ-2 — root access method
- **Found:** `cssource` needs a password for sudo; no NOPASSWD rule.
- **Decided:** do not add a sudoers rule. All root work goes through
  `scripts/rroot`, which pipes the sudo password from a local 0600 file
  (`~/.ssh/chogan_css.sudopw`, outside the repo) into `sudo -S`. Nothing about the
  account, its password, or sshd was changed.
- **Would confirm:** whether a NOPASSWD sudoers entry for a dedicated deploy user is
  acceptable for future automation.

## OQ-3 — SourceMod build pin (see D-005)
- **Decided:** SM 1.12.0-git7179 forever (until someone builds SM against the v92 SDK).
- **Would confirm:** whether the operator prefers SM 1.11 (last 1.11 builds also predate
  v93) — I chose 1.12 because the spec and all chosen plugins target 1.12.

## OQ-4 — No real CS:S client is available to this run
- **Found:** the operator machine has no Steam/CS:S install; a v92 non-Steam client can only come from
  community repacks (untrusted downloads, which this run does not perform). The VM cannot run a game client.
- **Decided:** prove the connect path at protocol level with `scripts/srcclient` (real Source-engine
  challenge/connect handshake + netchannel from the box itself), plus Valve bots for gameplay load, and
  flag clearly that the MISSION §6.2 "real client connects and plays" gate was satisfied only at that level.
- **Would confirm:** operator runs the launcher's v92 client against pub1 (`connect 212.80.8.87:27017`)
  with `setinfo lt <ticket>` set before connecting and sends me the console output + `sm_cgauth` output.

## OQ-5 — RevEmu provenance
- **Found:** bir3yk.net (the emulator author's site) is not reachable as a download source; the only
  GitHub packaging of the bir3yk RevEmu for Linux Source servers found so far is
  `Uphardt/RevEmu-2024-Uphardt-Edition-LINUX` (bin/steamclient.so 1.7 MB + rev.ini, 2024-02).
  rev.ini confirms the mechanism (`ClientDLL = ./bin/steamclient_valve.so`, `AllowLegit/AllowCracked/
  AllowUnknown`, `Check_Ticket`, `UseConectSM`).
- **Decided (pending research result):** use that package on the VM inside the sandboxed instance user,
  record sha256, and keep the Valve `steamclient.so` from buildid 6953255 as `steamclient_valve.so`.
- **Would confirm:** operator supplies the RevEmu build they ship to players (server and client side must
  agree on the ticket format); whether `AllowLegit` (Steam players) should stay on.

## OQ-6 — Non-Steam transport: RevEmu installed but a game-client connect could not be validated
- **Found:** RevEmu (08.10.2023 bir3yk Linux build, sha256 `ca1e6cc7…`, provenance
  cross-checked: hl2go mirror == Uphardt GitHub, identical bytes) is installed in the
  base and loads correctly — `rev-client.log`: `Startup` / `Using ClientDll
  "bin/steamclient_valve.so"` / `UserConnect IP=… SteamID=STEAM_0:1:1781007403`. But a
  connect attempt from `scripts/srcclient` with a forged/legacy (`rev2013`, 194-byte)
  ticket is rejected: RevEmu logs `Ticket: Unknown` and the engine's own
  `BeginAuthSession` returns `invalid ticket` → `#GameUI_ServerRejectSteam`. This
  matches `docs/revemu.md` §4c: the current RevEmu ticket is minted client-side by
  bir3yk's Themida-packed client from the HDD serial and (optionally) verified against
  bir3yk's backend — it is **not reproducible by a synthetic client**. So a *full
  non-Steam game-client connection* can only be proven with the actual launcher client.
- **Decided:** keep RevEmu installed (the spec's explicit choice) with a sane rev.ini
  (`Check_Ticket=False`, `AllowUnknown=True`, `RevEmu_2012=False`, `ClientDLL=./bin/
  steamclient_valve.so`); leave the servers on `sv_lan 0`. The **Chogan phone-account
  auth (setinfo `lt`) is fully proven and is independent of the RevEmu SteamID** — that
  is the identity system MISSION §3 asks for; RevEmu only governs whether a non-Steam
  *game client* can establish the connection at all.
- **Strongly recommend / would confirm:** evaluate **`srcdslab/sm-ext-connect` 1.4.1**
  with `sv_nosteam` as the non-Steam transport instead of RevEmu. It is a SourceMod
  extension that hooks `BeginAuthSession` and lets a plugin accept clients with **no
  backend and no proprietary client**, so it can be tested end-to-end with `srcclient`
  (a plain dummy ticket). Caveats: the published binary is built for ubuntu-24.04 /
  sm-1.12-dev, so it must be verified to load on this box (22.04) + pinned SM 7179, or
  rebuilt. This is an architecture choice the operator should make; I did not swap it in
  because RevEmu is what the spec names and the launcher's client emulator must match
  whatever the server runs — that pairing is the operator's integration point.
