#!/usr/bin/env bash
# 06 — nginx FastDL bound to 212.80.8.87:80 with limit_rate (MISSION §6.2). Idempotent. Run as root.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get purge -y -q nginx-light >/dev/null 2>&1 || true; apt-get install -y -q --no-install-recommends nginx-core bzip2 >/dev/null
mkdir -p /srv/fastdl/cstrike/maps /opt/css/content/cstrike/{maps,materials,models,sound}
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/fastdl /etc/nginx/sites-enabled/fastdl
nginx -t
systemctl enable --now nginx >/dev/null; systemctl reload nginx
/opt/css/bin/css-fastdl-sync
curl -s -o /dev/null -w "fastdl health: %{http_code}\n" http://212.80.8.87/health
ss -tlnp | grep ':80 '
echo "06-nginx-fastdl: OK"
