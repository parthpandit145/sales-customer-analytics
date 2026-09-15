-- =============================================================================
-- 07_analytics.sql
-- RFM, cohort retention, LTV and Pareto -- done in SQL, not DAX.
--
-- Everything below keys on customer_unique_id (the person), never customer_id
-- (which Olist re-issues per order).
--
-- One global convention: "today" is the last purchase date in the data set, not
-- now(). Olist ends in Oct 2018; measuring recency against the real clock would
-- put every customer ~8 years dormant and make RFM meaningless.
-- =============================================================================

CREATE OR REPLACE VIEW mart.v_analysis_date AS
SELECT
    max(f.purchase_date)                                   AS as_of_date,
    min(f.purchase_date)                                   AS data_start_date,
    date_trunc('month', max(f.purchase_date))::date        AS as_of_month
FROM mart.fact_orders f
WHERE f.is_valid_sale;


-- =============================================================================
-- vw_rfm : recency / frequency / monetary with segment labels
-- =============================================================================
CREATE OR REPLACE VIEW mart.vw_rfm AS
WITH base AS (
    SELECT
        f.customer_unique_id,
        min(f.purchase_date)                     AS first_order_date,
        max(f.purchase_date)                     AS last_order_date,
        count(*)                                 AS frequency,
        sum(f.order_total)                       AS monetary,
        round(avg(f.order_total), 2)             AS avg_order_value,
        round(avg(f.review_score), 2)            AS avg_review_score
    FROM mart.fact_orders f
    WHERE f.is_valid_sale
    GROUP BY f.customer_unique_id
),
scored AS (
    SELECT
        b.*,
        (a.as_of_date - b.last_order_date)       AS recency_days,
        -- R: quintile on recency. as_of_date is constant across the window, so
        -- ordering by last_order_date ascending is the same ranking with less
        -- arithmetic -- and it lands 5 on the most recent buyers.
        ntile(5) OVER (ORDER BY b.last_order_date) AS r_score,
        -- M: straight quintile on lifetime spend
        ntile(5) OVER (ORDER BY b.monetary)      AS m_score,
        -- F: NOT a quintile. ~97% of Olist customers order exactly once, so
        -- NTILE(5) on frequency puts identical customers in different buckets
        -- purely on tie-break order. Explicit bands are the honest treatment.
        CASE
            WHEN b.frequency = 1 THEN 1
            WHEN b.frequency = 2 THEN 3
            WHEN b.frequency = 3 THEN 4
            ELSE                      5
        END                                      AS f_score
    FROM base b
    CROSS JOIN mart.v_analysis_date a
),
segmented AS (
    SELECT
        s.*,
        round((s.f_score + s.m_score) / 2.0)::int AS fm_score
    FROM scored s
)
SELECT
    s.customer_unique_id,
    s.first_order_date,
    s.last_order_date,
    s.recency_days,
    s.frequency,
    s.monetary,
    s.avg_order_value,
    s.avg_review_score,
    s.r_score,
    s.f_score,
    s.m_score,
    s.fm_score,
    (s.r_score::text || s.f_score::text || s.m_score::text) AS rfm_cell,
    CASE
        WHEN s.r_score >= 4 AND s.fm_score >= 4 THEN 'Champions'
        WHEN s.r_score <= 2 AND s.fm_score  = 5 THEN 'Cannot Lose Them'
        WHEN s.r_score <= 2 AND s.fm_score >= 3 THEN 'At Risk'
        WHEN s.r_score >= 3 AND s.fm_score >= 3 THEN 'Loyal Customers'
        WHEN s.r_score  = 5                     THEN 'New Customers'
        WHEN s.r_score  = 4                     THEN 'Promising'
        WHEN s.r_score  = 3                     THEN 'Needs Attention'
        WHEN s.r_score  = 2                     THEN 'Hibernating'
        ELSE                                         'Lost'
    END AS rfm_segment,
    -- sort order for the report; Power BI sorts text alphabetically otherwise
    CASE
        WHEN s.r_score >= 4 AND s.fm_score >= 4 THEN 1
        WHEN s.r_score <= 2 AND s.fm_score  = 5 THEN 2
        WHEN s.r_score <= 2 AND s.fm_score >= 3 THEN 3
        WHEN s.r_score >= 3 AND s.fm_score >= 3 THEN 4
        WHEN s.r_score  = 5                     THEN 5
        WHEN s.r_score  = 4                     THEN 6
        WHEN s.r_score  = 3                     THEN 7
        WHEN s.r_score  = 2                     THEN 8
        ELSE                                         9
    END AS segment_rank,
    CASE
        WHEN s.r_score >= 4 AND s.fm_score >= 4 THEN 'Reward. Early access, referral asks.'
        WHEN s.r_score <= 2 AND s.fm_score  = 5 THEN 'Win back now. Personal outreach, high-value offer.'
        WHEN s.r_score <= 2 AND s.fm_score >= 3 THEN 'Reactivation campaign before they lapse for good.'
        WHEN s.r_score >= 3 AND s.fm_score >= 3 THEN 'Upsell and cross-sell. They already trust you.'
        WHEN s.r_score  = 5                     THEN 'Onboard. Second-purchase nudge within 30 days.'
        WHEN s.r_score  = 4                     THEN 'Build the habit. Category recommendations.'
        WHEN s.r_score  = 3                     THEN 'Re-engage with a reason to return.'
        WHEN s.r_score  = 2                     THEN 'Low-cost automated win-back only.'
        ELSE                                         'Do not spend. Suppress from paid targeting.'
    END AS recommended_action
FROM segmented s;


-- =============================================================================
-- vw_cohort : monthly retention triangle
-- Grain: one row per (cohort_month, month_index). Feed straight into a Power BI
-- matrix -- cohort on rows, month_index on columns, retention_pct in values.
-- =============================================================================
CREATE OR REPLACE VIEW mart.vw_cohort AS
WITH activity AS (
    SELECT DISTINCT
        f.customer_unique_id,
        date_trunc('month', f.purchase_date)::date AS activity_month
    FROM mart.fact_orders f
    WHERE f.is_valid_sale
),
first_month AS (
    SELECT
        a.customer_unique_id,
        min(a.activity_month) AS cohort_month
    FROM activity a
    GROUP BY a.customer_unique_id
),
cohort_size AS (
    SELECT cohort_month, count(*) AS cohort_customers
    FROM first_month
    GROUP BY cohort_month
),
joined AS (
    SELECT
        fm.cohort_month,
        a.activity_month,
        ( (extract(year  FROM a.activity_month) - extract(year  FROM fm.cohort_month)) * 12
        + (extract(month FROM a.activity_month) - extract(month FROM fm.cohort_month)) )::int AS month_index,
        a.customer_unique_id
    FROM activity a
    JOIN first_month fm ON fm.customer_unique_id = a.customer_unique_id
),
revenue AS (
    SELECT
        fm.cohort_month,
        date_trunc('month', f.purchase_date)::date AS activity_month,
        sum(f.order_total) AS cohort_revenue
    FROM mart.fact_orders f
    JOIN first_month fm ON fm.customer_unique_id = f.customer_unique_id
    WHERE f.is_valid_sale
    GROUP BY 1, 2
)
SELECT
    j.cohort_month,
    to_char(j.cohort_month, 'Mon YYYY')            AS cohort_month_label,
    to_char(j.cohort_month, 'YYYYMM')::int         AS cohort_month_key,
    j.month_index,
    'M' || lpad(j.month_index::text, 2, '0')       AS month_index_label,
    j.activity_month,
    cs.cohort_customers                            AS cohort_size,
    count(DISTINCT j.customer_unique_id)           AS active_customers,
    round(100.0 * count(DISTINCT j.customer_unique_id) / cs.cohort_customers, 2) AS retention_pct,
    coalesce(rv.cohort_revenue, 0)                 AS cohort_revenue,
    round(coalesce(rv.cohort_revenue, 0) / cs.cohort_customers, 2) AS revenue_per_cohort_customer
FROM joined j
JOIN cohort_size cs ON cs.cohort_month = j.cohort_month
LEFT JOIN revenue rv
       ON rv.cohort_month = j.cohort_month AND rv.activity_month = j.activity_month
CROSS JOIN mart.v_analysis_date ad
-- Do not emit cells for months that have not happened yet: an empty cell reads
-- as "no data", a 0.00 reads as "everybody churned". They are not the same.
WHERE j.activity_month <= ad.as_of_month
GROUP BY j.cohort_month, j.month_index, j.activity_month, cs.cohort_customers, rv.cohort_revenue;


-- =============================================================================
-- vw_customer_ltv : observed lifetime value + Pareto position
-- =============================================================================
CREATE OR REPLACE VIEW mart.vw_customer_ltv AS
WITH base AS (
    SELECT
        f.customer_unique_id,
        count(*)                                        AS total_orders,
        sum(f.order_revenue)                            AS product_revenue,
        sum(f.order_freight)                            AS freight_paid,
        sum(f.order_total)                              AS lifetime_value,
        round(avg(f.order_total), 2)                    AS avg_order_value,
        min(f.purchase_date)                            AS first_order_date,
        max(f.purchase_date)                            AS last_order_date,
        (max(f.purchase_date) - min(f.purchase_date))   AS lifespan_days,
        round(avg(f.review_score), 2)                   AS avg_review_score,
        sum(f.items_in_order)                           AS total_items,
        count(*) FILTER (WHERE f.is_late)               AS late_deliveries
    FROM mart.fact_orders f
    WHERE f.is_valid_sale
    GROUP BY f.customer_unique_id
),
ranked AS (
    SELECT
        b.*,
        row_number() OVER (ORDER BY b.lifetime_value DESC, b.customer_unique_id) AS revenue_rank,
        ntile(10)    OVER (ORDER BY b.lifetime_value DESC)                       AS ltv_decile,
        sum(b.lifetime_value) OVER (ORDER BY b.lifetime_value DESC, b.customer_unique_id
                                    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
                                                                                 AS running_revenue,
        sum(b.lifetime_value) OVER ()                                            AS total_revenue,
        count(*)              OVER ()                                            AS total_customers
    FROM base b
)
SELECT
    r.customer_unique_id,
    r.total_orders,
    r.total_items,
    r.product_revenue,
    r.freight_paid,
    r.lifetime_value,
    r.avg_order_value,
    r.first_order_date,
    r.last_order_date,
    r.lifespan_days,
    r.avg_review_score,
    r.late_deliveries,
    r.revenue_rank,
    r.ltv_decile,
    -- Pareto: what share of all revenue is captured by this customer and every
    -- customer richer than them. Plot rank% on X, this on Y for the 80/20 curve.
    round(100.0 * r.running_revenue / nullif(r.total_revenue, 0), 4) AS cumulative_revenue_pct,
    round(100.0 * r.revenue_rank    / nullif(r.total_customers, 0), 4) AS customer_percentile,
    CASE
        WHEN r.ltv_decile = 1        THEN '1. Top 10%'
        WHEN r.ltv_decile = 2        THEN '2. 10-20%'
        WHEN r.ltv_decile <= 5       THEN '3. 20-50%'
        ELSE                              '4. Bottom 50%'
    END AS ltv_tier,
    CASE
        WHEN r.lifetime_value <  50  THEN '1. Under R$50'
        WHEN r.lifetime_value < 100  THEN '2. R$50-100'
        WHEN r.lifetime_value < 250  THEN '3. R$100-250'
        WHEN r.lifetime_value < 500  THEN '4. R$250-500'
        ELSE                              '5. R$500+'
    END AS ltv_band
FROM ranked r;


-- =============================================================================
-- vw_category_pareto : the 80/20 on the product side
-- =============================================================================
CREATE OR REPLACE VIEW mart.vw_category_pareto AS
WITH base AS (
    SELECT
        p.category            AS category,
        p.category_group,
        sum(f.price)          AS product_revenue,
        sum(f.freight_value)  AS freight_cost,
        sum(f.item_total)     AS gross_revenue,
        count(*)              AS items_sold,
        count(DISTINCT f.order_id) AS orders
    FROM mart.fact_sales f
    JOIN mart.dim_product p ON p.product_id = f.product_id
    WHERE f.is_valid_sale
    GROUP BY p.category, p.category_group
),
ranked AS (
    SELECT
        b.*,
        row_number() OVER (ORDER BY b.gross_revenue DESC)                        AS revenue_rank,
        sum(b.gross_revenue) OVER (ORDER BY b.gross_revenue DESC
                                   ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_revenue,
        sum(b.gross_revenue) OVER ()                                             AS total_revenue
    FROM base b
)
SELECT
    r.category,
    r.category_group,
    r.revenue_rank,
    r.items_sold,
    r.orders,
    r.product_revenue,
    r.freight_cost,
    r.gross_revenue,
    round(100.0 * r.freight_cost / nullif(r.product_revenue, 0), 2) AS freight_pct_of_product_revenue,
    round(100.0 * r.gross_revenue / nullif(r.total_revenue, 0), 3)  AS pct_of_total_revenue,
    round(100.0 * r.running_revenue / nullif(r.total_revenue, 0), 3) AS cumulative_pct_of_revenue,
    (round(100.0 * r.running_revenue / nullif(r.total_revenue, 0), 3) <= 80) AS is_vital_few
FROM ranked r;
