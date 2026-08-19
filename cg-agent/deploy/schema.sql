-- cg-agent schema  (MariaDB 10.6+, utf8mb4).  Idempotent: safe to re-run.
--
-- Database/user come from server/provision/05-mariadb.sh:
--   database  chogan_agent
--   cg_agent@127.0.0.1   ALL            (the agent)
--   css_sm@127.0.0.1     SELECT/INSERT/UPDATE/DELETE  (SourceMod, for cg_auth_requests in the sql-transport fallback)
--
-- Apply:   mysql --protocol=socket -uroot chogan_agent < /path/to/schema.sql
--
-- Tables
--   accounts          phone accounts (local mode only; in remote mode the Chogan API owns accounts)
--   tickets           single-use login tickets, stored as SHA-256 only (local mode)
--   cg_events         event sink for POST /v1/event in local mode
--   cg_auth_requests  MISSION probe-2 fallback transport (plugin INSERTs, agent writes the verdict)

CREATE TABLE IF NOT EXISTS accounts (
  id           BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
  phone        VARCHAR(32)  NOT NULL,                      -- E.164, e.g. +989121234567 (never sent to the game server unmasked)
  display_name VARCHAR(64)  NOT NULL DEFAULT '',
  created_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uq_accounts_phone (phone)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- MISSION 6.3 redemption contract:
--   UPDATE tickets SET used_at = NOW()
--    WHERE hash = ? AND used_at IS NULL AND exp > NOW() AND server_id = ?
-- exactly one row affected == redeemed. The plaintext ticket is never stored.
CREATE TABLE IF NOT EXISTS tickets (
  hash       CHAR(64)     NOT NULL PRIMARY KEY,             -- lowercase hex SHA-256 of the plaintext ticket
  account_id BIGINT       NOT NULL,
  server_id  VARCHAR(32)  NOT NULL,                         -- pub1 | pub2 | dm | gg | awp | m1 | m2
  exp        DATETIME     NOT NULL,                         -- ~90 s after issue (DB clock)
  used_at    DATETIME     NULL,
  created_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  KEY ix_tickets_exp (exp),
  KEY ix_tickets_account (account_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS cg_events (
  id         BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
  server_id  VARCHAR(32)  NOT NULL,
  account_id BIGINT       NOT NULL DEFAULT 0,
  type       VARCHAR(32)  NOT NULL,                         -- connect | disconnect | kick | match_end | ...
  payload    JSON         NULL,                             -- MariaDB: LONGTEXT + json_valid() check
  created_at DATETIME     NOT NULL,                         -- stamped by the agent (UTC) when accepted
  KEY ix_events_created (created_at),
  KEY ix_events_account (account_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- SQL transport (fallback if RIPExt cannot do async HTTPS from SourcePawn, MISSION probe 2):
--   plugin (threaded MySQL):  INSERT INTO cg_auth_requests (ticket, server_id, ip, authid, name) VALUES (?,?,?,?,?)
--                             then poll  SELECT verdict, account_id, display_name, phone_masked, source, reason,
--                                               cache_hit, api_down FROM cg_auth_requests WHERE id = <insert id>
--                             until verdict IS NOT NULL (the agent polls every 250 ms; give up after ~10 s = api_down).
--   agent:  verdict 'ok' | 'fail', the same fields as the HTTP /v1/redeem response, ticket blanked, resolved_at set.
--   rows older than 1 hour are purged by the agent.
CREATE TABLE IF NOT EXISTS cg_auth_requests (
  id           BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
  ticket       VARCHAR(512) NOT NULL,                       -- plaintext from setinfo; blanked once resolved
  server_id    VARCHAR(32)  NOT NULL,
  ip           VARCHAR(45)  NOT NULL DEFAULT '',
  authid       VARCHAR(64)  NOT NULL DEFAULT '',
  name         VARCHAR(128) NOT NULL DEFAULT '',
  created_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  verdict      VARCHAR(8)   NULL,                           -- NULL = pending, 'ok' | 'fail'
  account_id   BIGINT       NULL,
  display_name VARCHAR(64)  NULL,
  phone_masked VARCHAR(32)  NULL,
  source       VARCHAR(8)   NULL,                           -- api | cache | stub | local
  reason       VARCHAR(16)  NULL,                           -- invalid | expired | used | scope | api_down
  cache_hit    TINYINT(1)   NOT NULL DEFAULT 0,
  api_down     TINYINT(1)   NOT NULL DEFAULT 0,
  resolved_at  DATETIME     NULL,
  KEY ix_car_pending (verdict, id),
  KEY ix_car_created (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Test data for local mode (harmless in production: fixed ids, INSERT IGNORE).
INSERT IGNORE INTO accounts (id, phone, display_name) VALUES
  (1001, '+989120000001', 'Test Player One'),
  (1002, '+989120000002', 'Test Player Two');
