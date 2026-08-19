#!/usr/bin/env bash
# install.sh - install or upgrade cg-agent on the VM. Run as root on the server, from a directory that
# holds bin/cg-agent (built with `make` on a Linux/amd64 box) and deploy/.  Idempotent.
#
#   sudo ./deploy/install.sh [path/to/cg-agent-binary]
#
# It does NOT touch an existing /etc/cg-agent/config.toml and does NOT apply the SQL schema
# (only needed for mode=local / sql_transport):
#   mysql --protocol=socket -uroot chogan_agent < deploy/schema.sql
set -euo pipefail
cd "$(dirname "$0")/.."
BIN=${1:-bin/cg-agent}
[ -x "$BIN" ] || { echo "install.sh: $BIN not found or not executable (run make first)"; exit 1; }

# 1. system user, no home, no shell
if ! id -u cg-agent >/dev/null 2>&1; then
  useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin cg-agent
fi

# 2. binary + config dir (dir 0750 root:cg-agent, file 0600 cg-agent:cg-agent because it carries secrets)
install -D -m 0755 -o root -g root "$BIN" /usr/local/bin/cg-agent
install -d -m 0750 -o root -g cg-agent /etc/cg-agent
if [ ! -e /etc/cg-agent/config.toml ]; then
  install -m 0600 -o cg-agent -g cg-agent deploy/config.example.toml /etc/cg-agent/config.toml
  echo "install.sh: wrote default (mode = stub) config to /etc/cg-agent/config.toml"
fi

# 3. unit
install -m 0644 -o root -g root deploy/cg-agent.service /etc/systemd/system/cg-agent.service
systemctl daemon-reload
systemctl enable cg-agent >/dev/null 2>&1 || true

# 4. validate config, (re)start, show status + health
/usr/local/bin/cg-agent -check -config /etc/cg-agent/config.toml
systemctl restart cg-agent
sleep 1
systemctl --no-pager --lines=5 status cg-agent || true
echo
curl -sS --max-time 2 http://127.0.0.1:8480/health || echo "install.sh: /health not answering yet"
echo
