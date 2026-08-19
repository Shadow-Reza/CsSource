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
