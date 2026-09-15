-- =============================================================================
-- 99_reset.sql  --  DESTRUCTIVE. Read before running.
--
-- Empties the landing zone and the pipeline's memory so the drip replays from
-- the beginning. seed.* is left alone, so you do NOT need to re-load the CSVs.
--
--   psql "$DATABASE_URL" -f sql/99_reset.sql
--   scripts/03_drip.sh
--
-- This exists so that sql/01_tables_seed_raw_ops.sql never has to be
-- destructive. Wiping data should be something you typed on purpose.
-- =============================================================================

TRUNCATE raw.orders, raw.order_items, raw.order_payments,
         raw.order_reviews, raw.customers;

TRUNCATE ops.load_errors, ops.dq_result, ops.load_batch RESTART IDENTITY CASCADE;

UPDATE ops.ingest_watermark
   SET last_purchase_ts = timestamp '2000-01-01',
       last_order_id    = NULL,
       orders_ingested  = 0,
       updated_at       = now()
 WHERE source_name = 'olist_orders';

SELECT 'reset complete -- raw is empty, watermark rewound, seed untouched' AS status,
       (SELECT count(*) FROM seed.orders) AS seed_orders_still_loaded;
