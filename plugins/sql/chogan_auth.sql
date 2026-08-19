-- chogan_auth.sql — tables touched by chogan_auth.smx when cg_auth_transport is "sql"
-- (MISSION §5 probe 2 fallback: SourceMod threaded MySQL instead of RIPExt).
--
-- Database: the cg-agent database (provision/05-mariadb.sh: DB_NAME_AGENT=chogan_agent),
-- reached from SourceMod through the "chogan" section of addons/sourcemod/configs/databases.cfg
-- (user css_sm has SELECT/INSERT/UPDATE/DELETE on it).
--
-- Contract (cg-agent/sqltransport.go in this repo):
--   plugin: INSERT INTO cg_auth_requests (ticket, server_id, ip, authid, name, created_at)
--   agent : rows WHERE verdict IS NULL -> verdict 'ok'|'fail', account_id, display_name,
--           phone_masked, source, reason, cache_hit, api_down, resolved_at; ticket blanked
--   plugin: SELECT verdict, account_id, display_name, reason, api_down FROM cg_auth_requests
--           WHERE id = ? AND verdict IS NOT NULL   (every 0.5 s, max cg_auth_timeout)
--   agent : housekeeping deletes rows older than 1 hour.
--
-- If cg-agent ships its own deploy/schema.sql, that file is authoritative; keep this one
-- column-compatible with it.

CREATE TABLE IF NOT EXISTS cg_auth_requests (
  id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  ticket        VARCHAR(512)    NOT NULL,                     -- blanked by the agent once resolved
  server_id     VARCHAR(64)     NOT NULL,
  ip            VARCHAR(45)     NOT NULL DEFAULT '',
  authid        VARCHAR(64)     NOT NULL DEFAULT '',
  name          VARCHAR(128)    NOT NULL DEFAULT '',
  created_at    DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  verdict       VARCHAR(8)      NULL,                         -- NULL = pending, 'ok' | 'fail'
  account_id    BIGINT          NULL,
  display_name  VARCHAR(64)     NULL,
  phone_masked  VARCHAR(32)     NULL,
  source        VARCHAR(16)     NULL,                         -- api | cache | stub | local
  reason        VARCHAR(32)     NULL,                         -- invalid | expired | used | scope | api_down
  cache_hit     TINYINT(1)      NOT NULL DEFAULT 0,
  api_down      TINYINT(1)      NOT NULL DEFAULT 0,
  resolved_at   DATETIME        NULL,
  PRIMARY KEY (id),
  KEY idx_pending (verdict, id),
  KEY idx_created (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- join/leave events written directly by the plugin in SQL-transport mode
-- (in RIPExt mode they go to POST /v1/event and the agent stores them in local mode).
CREATE TABLE IF NOT EXISTS cg_events (
  id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  server_id   VARCHAR(64)     NOT NULL,
  account_id  BIGINT          NOT NULL DEFAULT 0,
  type        VARCHAR(32)     NOT NULL,                       -- join | leave | ...
  payload     TEXT            NULL,                           -- JSON: {authid, ip, name, map, userid, source}
  created_at  DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_account (account_id, created_at),
  KEY idx_server (server_id, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
