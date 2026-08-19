# CsSource — Chogan Counter-Strike: Source server network

Server-side of the Chogan CS:Source platform: seven CS:S **v92** servers on one
Ubuntu 24.04 VM (`212.80.8.87`), systemd-supervised, shared read-only base
+ per-instance overlayfs, phone-number auth via `cg-agent` sidecar, MariaDB,
nginx FastDL, SMAC/Lilac anti-cheat, nftables firewall, A2S watchdog.

* **Start here if you are picking this up:** [docs/HANDOFF.md](docs/HANDOFF.md) — integration contract for the
  launcher/API team, rules for future sessions, and the prioritised to-do list.
* Spec: [MISSION.md](MISSION.md) — read it before touching anything.
* Operating guide: [docs/runbook.md](docs/runbook.md)
* Decisions / errors / versions: [docs/](docs/) · raw evidence: [docs/evidence/](docs/evidence/)
* Final report (Persian): [docs/FINAL-REPORT.md](docs/FINAL-REPORT.md)

Layout (filled in as the build progresses):

```
MISSION.md            the spec
docs/                 decisions, probes, open questions, final report
server/               everything that lives on the VM, mirrored 1:1 by path
  etc/systemd/...     unit files
  opt/css/...         instance configs, scripts
  etc/nginx/...       FastDL
  etc/nftables.conf   firewall
cg-agent/             the auth sidecar (Go)
plugins/              SourceMod plugins (SourcePawn) written for this project
scripts/              provisioning / helper scripts run from the operator side
```
