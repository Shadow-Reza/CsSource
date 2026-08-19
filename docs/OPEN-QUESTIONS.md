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
