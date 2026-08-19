#!/usr/bin/env bash
# 09 — install cg-agent (auth sidecar, MISSION §6.3) from a staged build. Expects /home/cssource/.build/cg-agent/{bin/cg-agent,deploy/*}
# (produced by scripts/build-cg-agent). Writes /etc/cg-agent/config.toml ONCE (stub mode + DB DSN + sql_transport on).
set -euo pipefail
SRC=/home/cssource/.build/cg-agent
[ -x $SRC/bin/cg-agent ] || { echo "build first: scripts/build-cg-agent" >&2; exit 1; }
id -u cg-agent >/dev/null 2>&1 || useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin cg-agent
install -D -m 0755 -o root -g root $SRC/bin/cg-agent /usr/local/bin/cg-agent
install -d -m 0750 -o root -g cg-agent /etc/cg-agent
install -m 0644 -o root -g root $SRC/deploy/cg-agent.service /etc/systemd/system/cg-agent.service
# shellcheck disable=SC1091
. /opt/css/etc/secrets/db.env
if [ ! -e /etc/cg-agent/config.toml ]; then
  umask 077
  sed -e 's|^mode = "stub"|mode = "stub"|' \
      -e "s|^dsn = \"\"|dsn = \"$DB_AGENT_USER:$DB_AGENT_PASS@tcp(127.0.0.1:3306)/$DB_NAME_AGENT?parseTime=true\"|" \
      -e 's|^enabled = false|enabled = true|' \
      $SRC/deploy/config.example.toml > /etc/cg-agent/config.toml
  chown cg-agent:cg-agent /etc/cg-agent/config.toml; chmod 0600 /etc/cg-agent/config.toml
  echo "wrote /etc/cg-agent/config.toml (mode=stub, db dsn set, sql_transport on)"
fi
mysql --protocol=socket -uroot "$DB_NAME_AGENT" < $SRC/deploy/schema.sql && echo "schema applied"
systemctl daemon-reload; systemctl enable cg-agent >/dev/null 2>&1 || true
/usr/local/bin/cg-agent -check -config /etc/cg-agent/config.toml
systemctl restart cg-agent; sleep 1
systemctl is-active cg-agent
curl -sS --max-time 3 http://127.0.0.1:8480/health; echo
curl -sS --max-time 3 -X POST http://127.0.0.1:8480/v1/redeem -H 'Content-Type: application/json' -d '{"ticket":"hello-world","server_id":"pub1","ip":"1.2.3.4","authid":"STEAM_0:0:1","name":"tester"}'; echo
curl -sS --max-time 3 -X POST http://127.0.0.1:8480/v1/redeem -H 'Content-Type: application/json' -d '{"ticket":"","server_id":"pub1","ip":"1.2.3.4","authid":"STEAM_0:0:1","name":"tester"}'; echo
mysql --protocol=socket -uroot "$DB_NAME_AGENT" -e "SHOW TABLES"
echo "09-cg-agent: OK"
