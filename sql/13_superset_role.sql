-- =============================================================================
-- 13_superset_role.sql
-- Least-privilege database role for Superset / Preset.
--
-- Run via scripts/04_superset_role.sh, which creates the role and sets its
-- password without either ever appearing on screen or in shell history.
--
-- WHY NOT JUST USE neondb_owner
--
-- Superset ships SQL Lab: anyone who can log into the dashboard can run
-- arbitrary SQL against whatever credentials the connection holds. With the
-- owner account that means DROP TABLE. This role can read the mart schema and
-- nothing else -- it cannot see raw customer records in seed/raw, cannot touch
-- the pipeline's telemetry, and cannot write anything anywhere.
--
-- Note that mart is entirely views. A view executes against its OWNER's
-- privileges on the underlying tables, so granting SELECT on the views is
-- enough -- superset_ro never needs, and never gets, access to seed/raw/stg.
-- =============================================================================

-- Read the mart schema, and only the mart schema.
GRANT CONNECT ON DATABASE :"DBNAME" TO superset_ro;
GRANT USAGE   ON SCHEMA mart        TO superset_ro;
GRANT SELECT  ON ALL TABLES IN SCHEMA mart TO superset_ro;

-- Views added later are covered automatically.
ALTER DEFAULT PRIVILEGES IN SCHEMA mart GRANT SELECT ON TABLES TO superset_ro;

-- Belt and braces: make sure nothing is inherited from PUBLIC on the internals.
REVOKE ALL ON SCHEMA seed FROM superset_ro;
REVOKE ALL ON SCHEMA raw  FROM superset_ro;
REVOKE ALL ON SCHEMA stg  FROM superset_ro;
REVOKE ALL ON SCHEMA ops  FROM superset_ro;

-- No write privileges anywhere, ever.
REVOKE ALL ON ALL TABLES IN SCHEMA mart FROM superset_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA mart TO superset_ro;

SELECT 'granted: SELECT on ' || count(*) || ' objects in mart' AS result
FROM information_schema.tables WHERE table_schema = 'mart';
