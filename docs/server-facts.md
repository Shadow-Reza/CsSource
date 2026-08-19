# Server facts (surveyed 2026-08-19 04:47 UTC, before any change)

| Item | Value |
|---|---|
| Host | `212.80.8.87/28`, gw `212.80.8.81`, iface `ens160`, DNS `4.2.2.4` (cloud-init netplan) |
| OS | **Ubuntu 22.04.5 LTS (jammy)**, kernel `5.15.0-190-generic` — spec said 24.04, see decisions |
| CPU | 8 vCPU, Intel Xeon E5-2697A v4 @ 2.60GHz, VMware, 2 sockets × 4 cores, no SMT |
| RAM | 15988 MB + 4095 MB swap |
| Disk | `/dev/sda2` ext4 59 GB, 7.4 GB used, 49 GB free (spec said 50 GB) |
| Login user | `cssource` (uid 1000, in `sudo`, password sudo) — SSH `PasswordAuthentication yes` via `/etc/ssh/sshd_config.d/50-cloud-init.conf`, **left untouched** |
| Operator key | `~/.ssh/chogan_css` (ed25519) added to `cssource` `authorized_keys` |
| Firewall | none active (`ufw` inactive, `nft` ruleset empty), only sshd:22 listening |
| Pre-installed | nothing relevant: no steamcmd, no i386 arch, no gcc/go, python3.10 |
| Kernel overlay | `overlay.ko` present |
| Time | UTC, timesyncd synced |
| unattended-upgrades | active (Update-Package-Lists=1, Unattended-Upgrade=1) |

Raw survey output is in `docs/evidence/00-survey.txt`.
