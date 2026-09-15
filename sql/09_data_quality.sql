-- =============================================================================
-- 09_data_quality.sql
-- Assertions that run after every batch. n8n fails the workflow loudly if any
-- 'error'-severity check comes back 'fail'.
--
-- A dashboard nobody trusts is a dashboard nobody uses. These are the checks
-- that would catch the failure modes this model actually has.
-- =============================================================================

-- Pure function: evaluates every assertion and returns the result set.
-- Side-effect free on purpose, so it can be run ad hoc without polluting history.
CREATE OR REPLACE FUNCTION ops.dq_checks()
RETURNS TABLE (
    check_name text,
    severity   text,
    status     text,
    observed   numeric,
    threshold  numeric,
    detail     text
)
LANGUAGE sql STABLE AS $$
    WITH checks AS (

        -- 1. Every order item must resolve to a product in the dimension.
        SELECT 'orphan_items_no_product'::text AS nm, 'error'::text AS sev,
               (SELECT count(*) FROM mart.fact_sales f
                 LEFT JOIN mart.dim_product p ON p.product_id = f.product_id
                WHERE p.product_id IS NULL)::numeric AS obs,
               0::numeric AS thr,
               'order items whose product_id is missing from dim_product'::text AS det

        -- 2. Every order must resolve to a customer.
        UNION ALL SELECT 'orphan_orders_no_customer', 'error',
               (SELECT count(*) FROM raw.orders o
                 LEFT JOIN raw.customers c ON c.customer_id = o.customer_id
                WHERE c.customer_id IS NULL)::numeric,
               0::numeric,
               'orders whose customer_id is missing from raw.customers'

        -- 3. Money is never negative.
        UNION ALL SELECT 'negative_amounts', 'error',
               (SELECT count(*) FROM raw.order_items
                 WHERE price < 0 OR freight_value < 0)::numeric,
               0::numeric,
               'order items with negative price or freight'

        -- 4. The two facts must agree on total revenue. If they diverge the
        --    item rollup in fact_orders has drifted from fact_sales.
        UNION ALL SELECT 'fact_revenue_reconciliation', 'error',
               (SELECT round(abs(
                    coalesce((SELECT sum(item_total)  FROM mart.fact_sales  WHERE is_valid_sale), 0)
                  - coalesce((SELECT sum(order_total) FROM mart.fact_orders WHERE is_valid_sale), 0)
               ), 2))::numeric,
               0.05::numeric,
               'absolute difference between fact_sales and fact_orders revenue'

        -- 5. fact_sales must be unique on its stated grain.
        UNION ALL SELECT 'fact_sales_grain_unique', 'error',
               (SELECT count(*) FROM (
                    SELECT order_item_key FROM mart.fact_sales
                    GROUP BY order_item_key HAVING count(*) > 1) d)::numeric,
               0::numeric,
               'duplicate order_item_key values in fact_sales'

        -- 6. Every purchase date must exist in the date dimension, or time
        --    intelligence silently drops those rows.
        UNION ALL SELECT 'dates_outside_dim_date', 'error',
               (SELECT count(*) FROM mart.fact_orders f
                 WHERE f.purchase_date < (SELECT min(date) FROM mart.dim_date)
                    OR f.purchase_date > (SELECT max(date) FROM mart.dim_date))::numeric,
               0::numeric,
               'orders whose purchase_date falls outside dim_date'

        -- 7. Review scores in range.
        UNION ALL SELECT 'review_score_out_of_range', 'error',
               (SELECT count(*) FROM raw.order_reviews
                 WHERE review_score NOT BETWEEN 1 AND 5)::numeric,
               0::numeric,
               'reviews outside the 1-5 scale'

        -- 8. Reject rate on the most recent ingest batch.
        UNION ALL SELECT 'batch_reject_rate_pct', 'warn',
               (SELECT round(100.0 * b.rows_rejected
                             / nullif(b.rows_loaded + b.rows_rejected, 0), 2)
                  FROM ops.load_batch b
                 WHERE b.source_name = 'olist_orders'
                   -- skip 'source drained' batches: a batch that moved nothing
                   -- has no meaningful reject rate and would mask the last real one
                   AND b.orders_attempted > 0
                 ORDER BY b.batch_id DESC LIMIT 1)::numeric,
               1.0::numeric,
               'share of rows rejected by the latest drip batch'

        -- 9. Payment totals that do not tie out to item totals. Expected to be
        --    non-zero (vouchers), so this is a warn with a tolerance, not an error.
        UNION ALL SELECT 'orders_with_payment_gap_pct', 'warn',
               (SELECT round(100.0 * count(*) FILTER (WHERE abs(payment_gap) > 1.0)
                             / nullif(count(*), 0), 2)
                  FROM mart.fact_orders WHERE is_valid_sale)::numeric,
               5.0::numeric,
               'share of orders where payments differ from item totals by more than R$1'

        -- 10. Products with no resolvable category.
        UNION ALL SELECT 'unknown_category_pct', 'warn',
               (SELECT round(100.0 * count(*) FILTER (WHERE category_key = 'unknown')
                             / nullif(count(*), 0), 2)
                  FROM mart.dim_product)::numeric,
               3.0::numeric,
               'share of products that fell through the category translation'

        -- 11. Grain sanity: customer_unique_id must be FEWER than customer_id.
        --     If these are equal, the person-vs-order key confusion has crept
        --     back in and every retention number is wrong.
        UNION ALL SELECT 'customer_grain_collapsed', 'error',
               (SELECT CASE WHEN count(DISTINCT customer_unique_id)
                                 >= count(DISTINCT customer_id)
                            THEN 1 ELSE 0 END
                  FROM raw.customers)::numeric,
               0::numeric,
               '1 means customer_unique_id is not deduplicating -- retention metrics invalid'

        -- 12. THE important one. An order the watermark has already passed over
        --     must be either in raw.orders or in ops.load_errors. Anything else
        --     is a silent drop -- the pipeline moved its cursor past a row and
        --     lost it. Zero tolerance, and correct to run mid-drip because it
        --     only looks behind the cursor.
        UNION ALL SELECT 'orders_skipped_silently', 'error',
               (SELECT count(*)
                  FROM seed.orders o
                 CROSS JOIN ops.ingest_watermark w
                 WHERE w.source_name = 'olist_orders'
                   AND ops.safe_ts(o.order_purchase_timestamp) IS NOT NULL
                   AND (ops.safe_ts(o.order_purchase_timestamp), o.order_id)
                       <= (w.last_purchase_ts, coalesce(w.last_order_id, ''))
                   AND NOT EXISTS (SELECT 1 FROM raw.orders r WHERE r.order_id = o.order_id)
                   AND NOT EXISTS (SELECT 1 FROM ops.load_errors e
                                    WHERE e.record_key = o.order_id))::numeric,
               0::numeric,
               'orders the watermark has passed that are in neither raw.orders nor ops.load_errors'

        -- 13. Coverage: how much of the source has been dripped in so far.
        UNION ALL SELECT 'ingest_completeness_pct', 'info',
               (SELECT round(100.0 * (SELECT count(*) FROM raw.orders)
                             / nullif((SELECT count(*) FROM seed.orders), 0), 2))::numeric,
               100.0::numeric,
               'raw.orders as a share of seed.orders'
    )
    SELECT c.nm,
           c.sev,
           CASE
               WHEN c.sev = 'info' THEN 'pass'
               WHEN c.obs IS NULL  THEN 'pass'
               WHEN c.obs <= c.thr THEN 'pass'
               ELSE 'fail'
           END,
           c.obs,
           c.thr,
           c.det
    FROM checks c;
$$;


-- -----------------------------------------------------------------------------
-- Wrapper: run the checks, persist them against a batch, hand them back to n8n.
-- n8n inspects the returned rows and fails the workflow if any error-severity
-- check came back 'fail'.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ops.run_dq_checks(p_batch_id bigint DEFAULT NULL)
RETURNS TABLE (
    check_name text,
    severity   text,
    status     text,
    observed   numeric,
    threshold  numeric,
    detail     text
)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO ops.dq_result (batch_id, check_name, severity, status, observed, threshold, detail)
    SELECT p_batch_id, c.check_name, c.severity, c.status, c.observed, c.threshold, c.detail
    FROM ops.dq_checks() c;

    RETURN QUERY SELECT * FROM ops.dq_checks();
END $$;

COMMENT ON FUNCTION ops.run_dq_checks(bigint) IS
    'Post-batch assertions. Any error-severity fail should stop the pipeline.';

-- Convenience view for the Power BI data-quality tile.
CREATE OR REPLACE VIEW mart.vw_pipeline_health AS
SELECT
    b.batch_id,
    b.source_name,
    b.started_at,
    b.finished_at,
    b.status,
    b.orders_attempted,
    b.rows_loaded,
    b.rows_rejected,
    round(extract(epoch FROM (b.finished_at - b.started_at))::numeric, 2) AS duration_seconds,
    round(100.0 * b.rows_rejected / nullif(b.rows_loaded + b.rows_rejected, 0), 3) AS reject_rate_pct,
    b.watermark_to
FROM ops.load_batch b
ORDER BY b.batch_id DESC;

CREATE OR REPLACE VIEW mart.vw_load_errors AS
SELECT
    e.error_id,
    e.batch_id,
    e.source_table,
    e.error_type,
    e.record_key,
    e.error_detail,
    e.logged_at
FROM ops.load_errors e;
