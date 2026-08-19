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
