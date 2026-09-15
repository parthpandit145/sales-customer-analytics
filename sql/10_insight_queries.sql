-- =============================================================================
-- 10_insight_queries.sql
-- Run these to fill in the real numbers in docs/06-insights.md.
-- Nothing here is used by the dashboard -- this is the analyst's notebook.
--
--   psql "$DATABASE_URL" -f sql/10_insight_queries.sql
-- =============================================================================

\echo '\n=== 1. Headline KPIs ==========================================='
SELECT
    to_char(count(DISTINCT f.order_id), 'FM999,999')            AS orders,
    to_char(count(DISTINCT f.customer_unique_id), 'FM999,999')  AS customers,
    to_char(sum(f.order_total), 'FM999,999,999.00')             AS revenue_brl,
    to_char(avg(f.order_total), 'FM999,990.00')                 AS aov_brl,
    to_char(sum(f.items_in_order), 'FM999,999')                 AS items,
    min(f.purchase_date)                                        AS first_day,
    max(f.purchase_date)                                        AS last_day
FROM mart.fact_orders f
WHERE f.is_valid_sale;

\echo '\n=== 2. Customer concentration (the 80/20 on people) ============'
SELECT
    'Top ' || pct || '% of customers' AS cohort,
    to_char(share, 'FM990.0') || '%'  AS share_of_revenue
FROM (
    SELECT 1 AS pct, (SELECT max(cumulative_revenue_pct) FROM mart.vw_customer_ltv WHERE customer_percentile <=  1) AS share
    UNION ALL SELECT  5, (SELECT max(cumulative_revenue_pct) FROM mart.vw_customer_ltv WHERE customer_percentile <=  5)
    UNION ALL SELECT 10, (SELECT max(cumulative_revenue_pct) FROM mart.vw_customer_ltv WHERE customer_percentile <= 10)
    UNION ALL SELECT 20, (SELECT max(cumulative_revenue_pct) FROM mart.vw_customer_ltv WHERE customer_percentile <= 20)
    UNION ALL SELECT 50, (SELECT max(cumulative_revenue_pct) FROM mart.vw_customer_ltv WHERE customer_percentile <= 50)
) t ORDER BY pct;

\echo '\n=== 3. Repeat purchase rate ===================================='
SELECT
    count(*)                                                        AS customers,
    count(*) FILTER (WHERE total_orders > 1)                        AS repeat_customers,
    round(100.0 * count(*) FILTER (WHERE total_orders > 1) / count(*), 2) AS repeat_pct,
    round(avg(total_orders), 3)                                     AS avg_orders_per_customer,
    round(avg(lifetime_value), 2)                                   AS mean_ltv,
    round(percentile_cont(0.5) WITHIN GROUP (ORDER BY lifetime_value)::numeric, 2) AS median_ltv
FROM mart.vw_customer_ltv;

\echo '\n=== 4. Cohort retention at M1 / M3 / M6 ========================'
\echo '(a cohort only appears at month_index N if it has existed that long,'
\echo ' so the base shrinks with N instead of being diluted by young cohorts)'
SELECT
    month_index,
    count(*)                  AS cohorts_old_enough,
    sum(cohort_size)          AS base_customers,
    sum(active_customers)     AS still_active,
    round(100.0 * sum(active_customers) / nullif(sum(cohort_size), 0), 2) AS retention_pct
FROM mart.vw_cohort
WHERE month_index IN (1, 3, 6, 12)
GROUP BY month_index
ORDER BY month_index;

\echo '\n=== 5. Category Pareto: how few categories carry 80% ==========='
SELECT
    count(*) FILTER (WHERE is_vital_few)                    AS categories_to_80pct,
    count(*)                                                AS categories_total,
    round(100.0 * count(*) FILTER (WHERE is_vital_few) / count(*), 1) AS pct_of_categories
FROM mart.vw_category_pareto;

\echo '\n--- top 10 categories by revenue ---'
SELECT revenue_rank, category, category_group,
       to_char(gross_revenue, 'FM999,999,999.00') AS revenue,
       pct_of_total_revenue AS pct_of_total,
       cumulative_pct_of_revenue AS cumulative_pct,
       freight_pct_of_product_revenue AS freight_pct
FROM mart.vw_category_pareto
ORDER BY revenue_rank LIMIT 10;

\echo '\n=== 6. Where freight erodes the margin ========================='
\echo '(high revenue AND high freight ratio = the categories worth repricing)'
SELECT category, category_group,
       to_char(gross_revenue, 'FM999,999,999') AS revenue,
       freight_pct_of_product_revenue          AS freight_pct_of_revenue,
       items_sold
FROM mart.vw_category_pareto
WHERE gross_revenue > (SELECT percentile_cont(0.75) WITHIN GROUP (ORDER BY gross_revenue)
                       FROM mart.vw_category_pareto)
ORDER BY freight_pct_of_product_revenue DESC
LIMIT 10;

\echo '\n=== 7. Does late delivery cost you the review? ================='
SELECT
    -- is_late is nullable (a delivered order can lack an estimated date), and
    -- a two-way CASE would silently file those under 'On time'
    CASE WHEN is_late IS NULL THEN 'Unknown'
         WHEN is_late        THEN 'Late'
         ELSE                     'On time' END AS delivery,
    count(*)                                  AS orders,
    round(avg(review_score), 2)               AS avg_review,
    round(100.0 * count(*) FILTER (WHERE review_score <= 2) / count(*), 1) AS detractor_pct,
    round(avg(order_total), 2)                AS aov
FROM mart.fact_orders
WHERE is_valid_sale AND is_delivered AND review_score IS NOT NULL
GROUP BY 1
ORDER BY delivery;

\echo '\n--- delivery speed bands vs review ---'
SELECT
    CASE
        WHEN delivery_days <=  3 THEN '1. 0-3 days'
        WHEN delivery_days <=  7 THEN '2. 4-7 days'
        WHEN delivery_days <= 14 THEN '3. 8-14 days'
        WHEN delivery_days <= 30 THEN '4. 15-30 days'
        ELSE                          '5. 30+ days'
    END AS speed_band,
    count(*)                    AS orders,
    round(avg(review_score), 2) AS avg_review,
    round(avg(order_total), 2)  AS aov
FROM mart.fact_orders
WHERE is_valid_sale AND is_delivered AND review_score IS NOT NULL
GROUP BY 1 ORDER BY 1;

\echo '\n=== 8. Geographic concentration ================================'
SELECT
    g.state_name, g.region,
    count(DISTINCT f.order_id)                          AS orders,
    to_char(sum(f.order_total), 'FM999,999,999')        AS revenue,
    round(100.0 * sum(f.order_total)
          / sum(sum(f.order_total)) OVER (), 2)         AS pct_of_revenue,
    round(avg(f.order_total), 2)                        AS aov,
    round(avg(f.delivery_days), 1)                      AS avg_delivery_days,
    round(avg(f.review_score), 2)                       AS avg_review
FROM mart.fact_orders f
JOIN mart.dim_geo g ON g.state_code = f.customer_state_code
WHERE f.is_valid_sale
GROUP BY g.state_name, g.region
ORDER BY sum(f.order_total) DESC
LIMIT 12;

\echo '\n=== 9. Payment mix and instalments ============================='
SELECT
    p.payment_type_label,
    count(*)                                            AS orders,
    round(100.0 * count(*) / sum(count(*)) OVER (), 1)  AS pct_of_orders,
    round(avg(f.order_total), 2)                        AS aov,
    round(avg(f.installments), 2)                       AS avg_installments,
    round(avg(f.review_score), 2)                       AS avg_review
FROM mart.fact_orders f
JOIN mart.dim_payment_type p ON p.payment_type = f.payment_type
WHERE f.is_valid_sale
GROUP BY p.payment_type_label, p.sort_order
ORDER BY p.sort_order;

\echo '\n=== 10. RFM segment sizes and value ============================'
SELECT
    rfm_segment,
    count(*)                                                   AS customers,
    round(100.0 * count(*) / sum(count(*)) OVER (), 1)         AS pct_of_customers,
    to_char(sum(monetary), 'FM999,999,999')                    AS revenue,
    round(100.0 * sum(monetary) / sum(sum(monetary)) OVER (), 1) AS pct_of_revenue,
    round(avg(monetary), 2)                                    AS avg_value,
    round(avg(recency_days))                                   AS avg_recency_days
FROM mart.vw_rfm
GROUP BY rfm_segment, segment_rank
ORDER BY segment_rank;

\echo '\n=== 11. Pipeline health ========================================'
SELECT batch_id, status, orders_attempted, rows_loaded, rows_rejected,
       reject_rate_pct, duration_seconds, watermark_to
FROM mart.vw_pipeline_health
LIMIT 10;

\echo '\n--- rejects by reason ---'
SELECT error_type, source_table, count(*) AS rows
FROM ops.load_errors
GROUP BY error_type, source_table
ORDER BY count(*) DESC;
