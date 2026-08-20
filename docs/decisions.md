# Decision log

Chronological. Each entry says what, why, and the alternative rejected.

## D-001 (2026-08-19) Repo & branch layout
- Public repo `Shadow-Reza/CsSource`. `main` holds the spec; all work on
  `build/chogan-css`; PR at the end, left unmerged (MISSION §2 rule 7).
- `core.autocrlf=false` + `.gitattributes eol=lf` because everything ships to Linux.

## D-002 (2026-08-19) Stay on Ubuntu 22.04 (see OQ-1)

## D-003 (2026-08-19) Remote access
- SSH key `chogan_css` (ed25519) added to `cssource`; password login untouched.
- `scripts/rsh` (user), `scripts/rroot` (root via `sudo -S`, password from local
  file), `scripts/rput` (scp + `install`). No secrets in the repo.

## D-004 (2026-08-19) Instance naming
- Instances: `pub1 pub2 dm gg awp m1 m2`; unit `css@<name>.service`; user `css-<name>`;
  tree `/opt/css/instances/<name>/{upper,work,root}`; shared base `/opt/css/base`.
- Overlay is mounted by `css-overlay@<name>.service` (oneshot, RemainAfterExit),
  which `css@` `BindsTo`/`After`s — keeps the game unit itself fully sandboxed and
  unprivileged.

## D-005 (2026-08-19) SourceMod pinned to 1.12.0-git7179 — spec §3 is wrong about "stock upstream 1.12"
- **Found:** current stock SM 1.12 (git7249) fails to load on v92: `Could not find interface:
  ServerGameClients005`. The Feb-2025 v93 update moved CS:S to the newer SDK
  (ServerGameClients005 / ServerGameDLL012); SM's `sourcemod.2.css.so` followed on
  2025-02-20 (build 7182). v92 exports ServerGameClients004 / ServerGameDLL010.
- **Decided:** pin `sourcemod-1.12.0-git7179-linux.tar.gz` (2025-02-17, last pre-v93
  build; sha256 in `docs/evidence/02-sm-interface-mismatch.txt`). It is still stock
  upstream 1.12, just not the newest build. Its gamedata is the pre-5d468dd2 set, so the
  §4.1 gamedata trap is moot *for the pinned build*; `DisableAutoUpdate=yes` still matters
  so the updater never pulls v93 gamedata into it.
- **Consequence:** the gamedata trap in §4.1 is subsumed by a bigger one — **no SM 1.12
  build newer than 7179 can run on v92 at all**, regardless of gamedata. Report loudly.
- Metamod:Source 1.12 git1225 is fine (its css loader accepts ServerGameClients003/004).

## D-006 (2026-08-19) Base file modes
- Base is `cssbase:css`, dirs 2775, files `u+rw,g+rw,o+r` (+x preserved). The SM 7179
  tarball ships files as 0600, which made `sourcemod.vdf` unreadable for the instance
  user → "No plugins loaded". `css-base-fixperms` now normalises read bits too.

## D-007 (2026-08-19) systemd mount-namespace wedge — base must never change under live overlays
- **Symptom seen:** after installing files into `/opt/css/base` **while four instances' overlays were still
  mounted**, every `css@` unit failed at `226/NAMESPACE`: `Failed to set up mount namespacing:
  /run/systemd/unit-root/dev: Invalid argument`. A trivial `systemd-run -p PrivateDevices=yes /bin/true` also
  failed, i.e. the host mount-namespace state was wedged, not the unit.
- **Fix:** `systemctl reboot` (a `daemon-reexec` alone did NOT clear it). After reboot every enabled unit
  auto-started cleanly and a normal stop-all/start-all cycle is stable (`docs/evidence/19-reboot-resilience.txt`).
- **Rule (already enforced by the provision scripts):** any change to the shared base MUST stop **all** `css@`
  and `css-overlay@` units first (the overlay lowerdir must not change while mounted). `css-base-fixperms`
  refuses if any overlay is mounted. Never `install` into `/opt/css/base` with instances running.
- `PrivateDevices` is not in the MISSION §6.1 list; it was kept because it works in normal operation, but if
  this ever recurs on a box that can't be rebooted, dropping `PrivateDevices=yes` from `css@.service` is the
  mitigation.

## D-008 (2026-08-20) Never give srcds a tty — it cost 7 cores at idle
- **Found:** with all seven servers empty the box ran at loadavg 8.5 (22.1 GHz in vSphere). Instances with
  **zero players and zero bots** still burned >100% of a core each, so bots were not the cause. `fps_max`,
  `smac_wallhack` and SourceTV were each ruled out by measurement. The cause was the `script -qfec` pty
  wrapper I had added to css-launch so console output would reach journald: with `-console` and a tty on
  stdin, srcds busy-polls its interactive console. Same instance: **95% with the pty, 3% without**.
- **Decided:** `css-launch` execs `srcds_run` directly with stdin on `/dev/null` (`stdbuf -oL -eL` keeps
  stdout line-buffered for journald), and `css@.service` now pins `StandardInput=null` so it cannot regress.
  Console-in-journald is not worth a core per instance; game logs live in `cstrike/logs/` regardless.
- **Also:** `bot_join_after_player 1` in every mode cfg (bots only once a human is present; bots measured at
  ~10-20% of a core per server), `fps_max` rendered to each instance's tickrate instead of a flat 300, and
  the dead `sv_hibernate_when_empty` / `sv_hibernate_ms` lines removed (those cvars do not exist on v92).
- **Result:** 7 idle servers went from ~744% to **18% of one core**; loadavg 8.5 -> 0.21.
- Evidence: `docs/evidence/22-idle-cpu-regression-and-fix.txt`.

## D-009 (2026-08-20) A 0600 my.cnf is silently ignored by mysqld
- **Found:** `/etc/mysql/mariadb.conf.d/60-chogan.cnf` was written under a `umask 077` in `05-mariadb.sh`,
  so it was `0600 root:root`. mysqld runs as `mysql` and **silently ignores config files it cannot read** —
  none of the tuning had ever applied (`skip_name_resolve=0`, `max_connections=151`, defaults throughout).
  The server was only bound to loopback because that is Ubuntu's packaged default, not because of our file.
- **Decided:** the provisioning script now `chmod 0644`s the file and ends by SELECTing the values back to
  prove they took effect. Right-sized for a schema holding a few hundred KB: `innodb_buffer_pool_size 64M`,
  `max_connections 60`, `performance_schema OFF`.
- **Lesson for future sessions:** after writing any config for a service that drops privileges, verify the
  service actually read it — do not assume a written file is an applied file.
