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
