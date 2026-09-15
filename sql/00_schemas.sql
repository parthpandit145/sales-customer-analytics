-- =============================================================================
-- 00_schemas.sql  |  Sales & Customer Analytics
-- Run once, first. Creates the schema layers and required extensions.
-- =============================================================================
--
-- Layer design (read top to bottom = data flow):
--
--   seed  -> one-time bulk copy of the Olist CSVs. Stands in for "the source
--            system". Nothing downstream reads it except the n8n drip job.
--   raw   -> landing zone the n8n pipeline writes into, batch by batch.
--            Append-only, no cleaning, keeps a batch_id for lineage.
--   stg   -> cleaning / conformance views. Types, trims, casing, dedupe, nulls.
--   mart  -> the star schema + analytical views. This is the ONLY layer
--            Power BI is allowed to touch.
--   ops   -> pipeline telemetry: batch log, rejected rows, watermarks, DQ runs.
--
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS seed;
CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS stg;
CREATE SCHEMA IF NOT EXISTS mart;
CREATE SCHEMA IF NOT EXISTS ops;

-- unaccent is used to normalise Brazilian city names (São Paulo -> Sao Paulo).
-- Available on Neon by default.
CREATE EXTENSION IF NOT EXISTS unaccent WITH SCHEMA public;

COMMENT ON SCHEMA seed IS 'One-time bulk load of source CSVs. Simulated source system.';
COMMENT ON SCHEMA raw  IS 'Landing zone written by the n8n pipeline, append-only, batch-tagged.';
COMMENT ON SCHEMA stg  IS 'Cleaning and conformance views. No business logic.';
COMMENT ON SCHEMA mart IS 'Star schema and analytical views. The Power BI contract.';
COMMENT ON SCHEMA ops  IS 'Pipeline telemetry: batches, rejected rows, watermarks, data quality.';
