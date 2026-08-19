# Runbook — operating the Chogan CS:S box (212.80.8.87)

Everything below is true as of the build run on 2026-08-19. Paths are on the VM.

## Layout
| Path | What |
|---|---|
| `/opt/css/base` | shared read-only game install (CS:S v92 buildid 6953255 + MM:S 1.12 git1225 + SM 1.12 **git7179** + RIPExt 1.3.2 + SMAC + Lilac). Owner `cssbase:css`, dirs 2775, files g+rw. **Never edit while an overlay is mounted.** |
| `/opt/css/instances/<i>/{upper,work,root,home}` | per-instance overlay (`root` = merged view srcds runs in; `upper` = that instance's writes) |
| `/opt/css/etc/instances/<i>.env` | ports/slots/tick/map/mode/hostname per instance (repo: `server/opt/css/etc/instances/`) |
| `/opt/css/etc/templates/` | server.cfg / mode cfgs / mapcycles / SM configs templates (repo mirror) |
| `/opt/css/etc/secrets/` | `db.env` (MariaDB creds), `<i>.env` (RCON_PASSWORD). root-only. **Not in the repo.** |
| `/opt/css/etc/admins_simple.ini` | live SM admin list (name+password / ip auth). Re-run `css-genconf <i>` + `sm_reloadadmins` after editing. |
| `/opt/css/bin/` | `css-overlay css-launch css-genconf css-rcon css-watchdog css-janitor css-loadtest css-fastdl-sync css-base-fixperms` |
| `/opt/css/dist/` | downloaded tarballs + SHA256SUMS |
| `/opt/css/content/cstrike/` | custom content staging → `css-fastdl-sync` → `/srv/fastdl/cstrike` (nginx, port 80, 1500k limit_rate) |
| `/etc/cg-agent/config.toml` | auth sidecar config (mode stub/local/remote). `/usr/local/bin/cg-agent`, unit `cg-agent.service`, :8480 loopback |
| `/etc/nftables.conf` | firewall (repo: `server/etc/nftables.conf`). Sets `operator_v4`, `monitoring_v4`, `blocklist_v4` |
| `/var/log/css/` | steamcmd logs, loadtest JSON |

Instances: `pub1 pub2 dm gg awp m1 m2` → units `css@<i>` (+ `css-overlay@<i>`), users `css-<i>` (group `css`).

## Daily operations
```bash
systemctl status css@pub1                  # one instance
systemctl start|stop|restart css@dm        # overlay unit is pulled in automatically
journalctl -u css@gg -f                    # console output
/opt/css/bin/css-rcon pub1 "status"        # RCON from the box (password from secrets)
/opt/css/bin/css-rcon pub1 "sm plugins list"
/opt/css/bin/css-watchdog                  # run the A2S watchdog once by hand (timer runs it every 30 s)
/opt/css/bin/css-janitor                   # demo/log caps (daily timer)
/opt/css/bin/css-loadtest --instances pub1,pub2 --settle 60   # probe-4 style measurement
```
Re-render configs after editing env/templates/secrets: `systemctl start css-overlay@<i> && /opt/css/bin/css-genconf <i> && systemctl restart css@<i>`.
From the operator machine: `scripts/deploy-server-tree` pushes `server/` to the VM; `scripts/rroot`/`rsh` run commands; `scripts/build-plugins` compiles SourcePawn on the VM; `scripts/build-cg-agent` builds the sidecar there.

## Changing the shared base (game files, SM/MM, plugins for all instances)
1. `systemctl stop 'css@*'` and `systemctl stop 'css-overlay@*'` (overlay lower layer must not change while mounted).
2. Make the change in `/opt/css/base` (or re-run `server/provision/04-…`, `07-…`).
3. `/opt/css/bin/css-base-fixperms` (fixes owner/modes; refuses if an overlay is mounted).
4. Start instances again. Per-instance files in `upper/` override base files forever — if you replace a base file that an instance had already copied-up, delete it from that instance's `upper/` too.

Do **not** upgrade SourceMod past 1.12.0-git7179 (newer builds need ServerGameClients005 → they do not load on v92; see `docs/decisions.md` D-005). Never let SM's updater run (`DisableAutoUpdate yes` in core.cfg, `-noupdate`).

## Adding a custom map
Copy `foo.bsp` to `/opt/css/base/cstrike/maps/` (base change → stop instances first) **and** to `/opt/css/content/cstrike/maps/`, run `css-fastdl-sync`, add the map to `server/opt/css/etc/templates/mapcycles/<mode>.txt`, redeploy, `css-genconf`.

## Firewall
`nft list ruleset`. Add an admin IP: `nft add element inet filter operator_v4 { 1.2.3.4 }` (edit `/etc/nftables.conf` to persist). Monitoring IP for A2S: set `monitoring_v4`. Ban: `nft add element inet filter blocklist_v4 { 1.2.3.4 timeout 24h }`. RCON TCP is only reachable from loopback + `operator_v4`; A2S query opcodes only from `monitoring_v4`/`operator_v4`.

## Auth sidecar
`systemctl status cg-agent`; `curl -s 127.0.0.1:8480/health | jq`; switch to the real API: edit `/etc/cg-agent/config.toml` → `mode = "remote"` + `[api] token`, `systemctl restart cg-agent`. The plugin fails **open** by default (`cg_auth_mode 1`): agent down ⇒ players enter as guests.

## Secrets rotation
RCON: delete `/opt/css/etc/secrets/<i>.env`, `css-genconf <i>`, restart the instance. DB: change in MariaDB + `db.env`, re-run genconf for all instances, update `/etc/cg-agent/config.toml`.
