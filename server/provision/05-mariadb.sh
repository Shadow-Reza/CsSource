#!/usr/bin/env bash
# 05 — MariaDB (loopback only) + databases/users for SourceMod and cg-agent. Idempotent. Run as root.
# Secrets are generated here and stored in /opt/css/etc/secrets/db.env (0600 root) — never in the repo.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -q --no-install-recommends mariadb-server mariadb-client >/dev/null
install -d -m 750 /opt/css/etc/secrets
SEC=/opt/css/etc/secrets/db.env
if [ ! -s "$SEC" ]; then
  umask 077
  cat > "$SEC" <<EOS
# generated $(date -u +%FT%TZ) by 05-mariadb.sh
DB_SM_USER=css_sm
DB_SM_PASS=$(openssl rand -hex 20)
DB_AGENT_USER=cg_agent
DB_AGENT_PASS=$(openssl rand -hex 20)
DB_NAME_SM=css_sourcemod
DB_NAME_AGENT=chogan_agent
EOS
fi
# shellcheck disable=SC1090
. "$SEC"
# NOTE: this file MUST be world-readable. mysqld runs as the `mysql` user and silently IGNORES any
# .cnf it cannot read -- with the 0600 that `umask 077` above would give it, none of these settings
# applied and the server ran on stock defaults. Always chmod 0644 and verify with a SELECT afterwards.
cat > /etc/mysql/mariadb.conf.d/60-chogan.cnf <<'EOS'
[mysqld]
bind-address = 127.0.0.1
skip-name-resolve
# right-sized for this workload: the two Chogan schemas hold a few hundred KB, not gigabytes
max_connections = 60
innodb_buffer_pool_size = 64M
innodb_log_file_size = 32M
performance_schema = OFF
innodb_flush_log_at_trx_commit = 2
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
EOS
chmod 0644 /etc/mysql/mariadb.conf.d/60-chogan.cnf
chown root:root /etc/mysql/mariadb.conf.d/60-chogan.cnf
systemctl enable --now mariadb >/dev/null
systemctl restart mariadb
mysql --protocol=socket -uroot <<EOS
CREATE DATABASE IF NOT EXISTS \`$DB_NAME_SM\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS \`$DB_NAME_AGENT\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_SM_USER'@'127.0.0.1' IDENTIFIED BY '$DB_SM_PASS';
ALTER USER '$DB_SM_USER'@'127.0.0.1' IDENTIFIED BY '$DB_SM_PASS';
CREATE USER IF NOT EXISTS '$DB_AGENT_USER'@'127.0.0.1' IDENTIFIED BY '$DB_AGENT_PASS';
ALTER USER '$DB_AGENT_USER'@'127.0.0.1' IDENTIFIED BY '$DB_AGENT_PASS';
GRANT ALL PRIVILEGES ON \`$DB_NAME_SM\`.* TO '$DB_SM_USER'@'127.0.0.1';
GRANT ALL PRIVILEGES ON \`$DB_NAME_AGENT\`.* TO '$DB_AGENT_USER'@'127.0.0.1';
-- the SQL-transport fallback table lives in the agent DB; SM needs rw on it too
GRANT SELECT, INSERT, UPDATE, DELETE ON \`$DB_NAME_AGENT\`.* TO '$DB_SM_USER'@'127.0.0.1';
FLUSH PRIVILEGES;
EOS
mysql --protocol=socket -uroot -e "SELECT user,host FROM mysql.user WHERE user IN ('$DB_SM_USER','$DB_AGENT_USER'); SHOW DATABASES LIKE 'c%';"
ss -tlnp | grep 3306
# prove the tuning file was actually read (a 0600 cnf is silently ignored by mysqld)
mysql --protocol=socket -uroot -e "SELECT @@skip_name_resolve, @@max_connections, @@innodb_buffer_pool_size/1024/1024 AS pool_mb, @@performance_schema;"
echo "05-mariadb: OK"
