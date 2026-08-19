#!/usr/bin/env bash
# 02 — fetch CS:S v92 (app 232330, beta 'previous_build', expected buildid 6953255) into /opt/css/base.
# +force_install_dir MUST precede +login (MISSION §3). Run as root; steamcmd runs as cssbase.
set -euxo pipefail
BASE=/opt/css/base
sudo -u cssbase -H bash -c "cd /opt/css/steamcmd && ./steamcmd.sh +force_install_dir $BASE +login anonymous +app_update 232330 -beta previous_build validate +quit" \
  2>&1 | tee -a /var/log/css/steamcmd-232330.log
echo "--- appmanifest ---"
grep -E '"(appid|buildid|name|StateFlags|LastUpdated)"' $BASE/steamapps/appmanifest_232330.acf || true
echo "--- tree ---"
ls -la $BASE; ls $BASE/cstrike | head -30
du -sh $BASE
echo "02-download-css-v92: OK"
