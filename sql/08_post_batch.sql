-- =============================================================================
-- 08_post_batch.sql
-- The materialised layer, and what runs after every ingest batch.
--
-- WHAT GETS MATERIALISED, AND WHY IT CHANGED
--
-- This project originally materialised every mart object, for Power BI. That
-- was wrong and got deleted: Power BI *imports* each table once per scheduled
-- refresh -- twice a day -- so shaving a second off a read that happens twice a
-- day buys nothing, while the copies cost 163 MB of a 512 MB tier and needed
-- another 54 MB of transient headroom during REFRESH, which blew the limit.
--
-- Superset is the opposite access pattern. It queries the database LIVE, on
-- every chart render and every filter change. A dashboard with eight charts is
-- eight queries, and the user is sitting there watching. Now recomputation cost
-- matters, and materialising pays.
--
-- Measured on the full dataset, full scan of the flattened Superset views:
--
--     dataset        views only    with the layer below
--     bi_sales           2.70 s       1.17 s
--     bi_orders          1.14 s       0.86 s
--     bi_customer        3.86 s       0.17 s     <- 23x
--
-- Only three objects are materialised, and they are the three that stack window
-- functions over 96k customers: dim_customer, vw_rfm, vw_customer_ltv. Together
-- they cost 66 MB. The fact views are left live -- they are plain scans, they
-- are the largest objects, and materialising them would put the database back
-- near the limit for a gain of about a second.
--
-- The rule, stated once: materialise where recomputation is expensive relative
-- to how often it is read. Not before you know which of those two is true.
-- =============================================================================

CREATE MATERIALIZED VIEW IF NOT EXISTS mart.mv_dim_customer AS SELECT * FROM mart.dim_customer;
CREATE MATERIALIZED VIEW IF NOT EXISTS mart.mv_rfm          AS SELECT * FROM mart.vw_rfm;
CREATE MATERIALIZED VIEW IF NOT EXISTS mart.mv_customer_ltv AS SELECT * FROM mart.vw_customer_ltv;

-- These unique indexes are not optional. REFRESH MATERIALIZED VIEW CONCURRENTLY
-- requires one, and without CONCURRENTLY the refresh takes an ACCESS EXCLUSIVE
-- lock -- which, with a live dashboard pointed at these objects, means every
-- chart hangs until the refresh finishes. They also double as a grain assertion:
-- if one fails to build, the view is producing duplicate customers.
CREATE UNIQUE INDEX IF NOT EXISTS ux_mv_dim_customer ON mart.mv_dim_customer (customer_unique_id);
CREATE UNIQUE INDEX IF NOT EXISTS ux_mv_rfm          ON mart.mv_rfm          (customer_unique_id);
CREATE UNIQUE INDEX IF NOT EXISTS ux_mv_customer_ltv ON mart.mv_customer_ltv (customer_unique_id);

-- Filter support for the Superset datasets built on top of these
CREATE INDEX IF NOT EXISTS ix_mv_dc_state   ON mart.mv_dim_customer (customer_state_code);
CREATE INDEX IF NOT EXISTS ix_mv_dc_cohort  ON mart.mv_dim_customer (cohort_month);
CREATE INDEX IF NOT EXISTS ix_mv_rfm_seg    ON mart.mv_rfm (rfm_segment);
CREATE INDEX IF NOT EXISTS ix_mv_ltv_tier   ON mart.mv_customer_ltv (ltv_tier);


-- -----------------------------------------------------------------------------
-- ops.post_batch_maintenance()
-- Called by n8n at the end of every ingest batch, and by scripts/03_drip.sh.
--
-- Two jobs: refresh the planner's statistics on the landing tables (raw.* grows
-- 1000 rows at a time, and stale statistics are exactly what turns a 0.4 s index
-- scan into a 20 s sequential one), then rebuild the materialised layer so the
-- dashboard is never more than one batch behind.
-- -----------------------------------------------------------------------------
-- CREATE OR REPLACE cannot change a function's return type, and this one grew
-- a `step` column, so drop first to keep the file re-runnable.
DROP FUNCTION IF EXISTS ops.post_batch_maintenance();

CREATE FUNCTION ops.post_batch_maintenance()
RETURNS TABLE (step text, object_name text, row_count bigint, seconds numeric)
LANGUAGE plpgsql AS $$
DECLARE
    v_obj  text;
    v_t0   timestamptz;
    v_rows bigint;
BEGIN
    FOREACH v_obj IN ARRAY ARRAY['raw.orders','raw.order_items','raw.order_payments',
                                 'raw.order_reviews','raw.customers'] LOOP
        v_t0 := clock_timestamp();
        EXECUTE format('ANALYZE %s', v_obj);
        EXECUTE format('SELECT count(*) FROM %s', v_obj) INTO v_rows;
        step := 'analyze'; object_name := v_obj; row_count := v_rows;
        seconds := round(extract(epoch FROM (clock_timestamp() - v_t0))::numeric, 3);
        RETURN NEXT;
    END LOOP;

    FOREACH v_obj IN ARRAY ARRAY['mart.mv_dim_customer','mart.mv_rfm','mart.mv_customer_ltv'] LOOP
        v_t0 := clock_timestamp();
        -- CONCURRENTLY: readers are not blocked, so a dashboard open during the
        -- refresh keeps serving the previous version instead of hanging.
        EXECUTE format('REFRESH MATERIALIZED VIEW CONCURRENTLY %s', v_obj);
        EXECUTE format('SELECT count(*) FROM %s', v_obj) INTO v_rows;
        step := 'refresh'; object_name := v_obj; row_count := v_rows;
        seconds := round(extract(epoch FROM (clock_timestamp() - v_t0))::numeric, 3);
        RETURN NEXT;
    END LOOP;
END $$;

COMMENT ON FUNCTION ops.post_batch_maintenance() IS
    'ANALYZE the landing tables and refresh the materialised customer layer. Called by n8n after each batch.';

DROP FUNCTION IF EXISTS ops.refresh_marts();
