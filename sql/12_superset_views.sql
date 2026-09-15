-- =============================================================================
-- 12_superset_views.sql
-- Wide, flattened views for Apache Superset.
--
-- WHY THIS FILE EXISTS
--
-- Power BI has a semantic model: you import a star schema, define relationships
-- once, and every chart can pull a measure from the fact and a label from any
-- dimension. Superset has no such thing. A Superset chart is built on exactly
-- ONE dataset, and a dataset is one table or one SQL query. There is no
-- relationship layer, so the joins have to be resolved before Superset sees the
-- data.
--
-- So the star schema gets flattened here. The dimensional model in 04-07 is
-- still the source of truth -- these views are a presentation layer on top of
-- it, not a replacement. Every join below is fact -> dimension on a key the
-- model already guarantees, so nothing can fan out and no measure gets
-- duplicated.
--
-- These are views, not tables: they cost no storage, and they cannot go stale.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- bi_sales : ONE ROW PER ORDER ITEM. The workhorse dataset.
-- Use for: revenue, freight, product, category, seller, geography, Pareto.
-- Do NOT use for: review scores or delivery times -- see bi_orders.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW mart.bi_sales AS
SELECT
    -- grain / keys ------------------------------------------------------
    f.order_item_key,
    f.order_id,
    f.order_item_id,
    f.customer_unique_id,
    f.product_id,
    f.seller_id,

    -- time --------------------------------------------------------------
    f.purchase_date,
    d.year                          AS purchase_year,
    d.quarter                       AS purchase_quarter,
    d.year_quarter,
    d.month_number                  AS purchase_month_number,
    d.month_name                    AS purchase_month_name,
    d.month_start                   AS purchase_month,
    d.year_month,
    d.year_month_label,
    d.week_start                    AS purchase_week,
    d.day_name                      AS purchase_day_name,
    d.day_of_week                   AS purchase_day_of_week,
    d.is_weekend,

    -- customer geography ------------------------------------------------
    c.customer_city,
    c.customer_state,
    c.customer_state_code,
    c.customer_region,
    g.latitude                      AS customer_latitude,
    g.longitude                     AS customer_longitude,
    c.cohort_month,
    c.cohort_month_label,
    c.is_repeat_customer,

    -- product ------------------------------------------------------------
    p.category                      AS product_category,
    p.category_group                AS product_category_group,
    p.weight_band                   AS product_weight_band,
    p.photo_band                    AS product_photo_band,
    p.weight_g                      AS product_weight_g,
    p.volume_cm3                    AS product_volume_cm3,

    -- seller -------------------------------------------------------------
    s.seller_state,
    s.seller_region,

    -- payment ------------------------------------------------------------
    coalesce(pt.payment_type_label, 'Unknown') AS payment_method,
    f.installments,

    -- order context ------------------------------------------------------
    f.order_status,
    f.is_valid_sale,
    f.is_delivered,
    f.items_in_order,
    f.order_seq,
    f.is_first_order,
    CASE WHEN f.is_first_order THEN 'New' ELSE 'Returning' END AS customer_type,

    -- measures -----------------------------------------------------------
    f.price,
    f.freight_value,
    f.item_total,
    f.allocated_payment,

    -- Order-level attributes, carried for FILTERING only. Averaging these at
    -- item grain weights every order by how many items it contained -- the
    -- _order_ suffix is the reminder. Use bi_orders to measure them.
    f.review_score_oa               AS order_review_score,
    f.review_band_oa                AS order_review_band
FROM mart.fact_sales f
JOIN      mart.dim_date         d  ON d.date          = f.purchase_date
JOIN      mart.mv_dim_customer  c  ON c.customer_unique_id = f.customer_unique_id
JOIN      mart.dim_product      p  ON p.product_id    = f.product_id
LEFT JOIN mart.dim_seller       s  ON s.seller_id     = f.seller_id
LEFT JOIN mart.dim_geo          g  ON g.state_code    = f.customer_state_code
LEFT JOIN mart.dim_payment_type pt ON pt.payment_type = f.payment_type;

COMMENT ON VIEW mart.bi_sales IS
    'Superset dataset: one row per order item, all dimensions flattened in.';


-- -----------------------------------------------------------------------------
-- bi_orders : ONE ROW PER ORDER.
-- Use for: AOV, review scores, delivery performance, new vs returning, payments.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW mart.bi_orders AS
SELECT
    f.order_id,
    f.customer_unique_id,

    -- time --------------------------------------------------------------
    f.purchase_date,
    f.delivered_date,
    d.year                          AS purchase_year,
    d.quarter                       AS purchase_quarter,
    d.year_quarter,
    d.month_name                    AS purchase_month_name,
    d.month_start                   AS purchase_month,
    d.year_month,
    d.year_month_label,
    d.week_start                    AS purchase_week,
    d.day_name                      AS purchase_day_name,
    d.is_weekend,

    -- customer geography ------------------------------------------------
    c.customer_city,
    c.customer_state,
    c.customer_state_code,
    c.customer_region,
    g.latitude                      AS customer_latitude,
    g.longitude                     AS customer_longitude,
    c.cohort_month,
    c.cohort_month_label,

    -- status / segmentation ---------------------------------------------
    f.order_status,
    f.is_valid_sale,
    f.is_delivered,
    f.is_cancelled,
    f.order_seq,
    f.is_first_order,
    f.customer_type,

    -- basket -------------------------------------------------------------
    f.items_in_order,
    f.distinct_products,
    f.distinct_sellers,
    f.order_revenue,
    f.order_freight,
    f.order_total,

    -- payment ------------------------------------------------------------
    coalesce(pt.payment_type_label, 'Unknown') AS payment_method,
    f.installments,
    f.payment_total,
    f.payment_gap,

    -- experience ---------------------------------------------------------
    f.review_score,
    f.review_band,
    f.has_comment,
    f.delivery_days,
    f.promised_days,
    f.days_vs_promise,
    f.is_late,
    -- pre-banded so Superset does not need a CASE in every chart
    CASE
        WHEN f.delivery_days IS NULL  THEN 'Not delivered'
        WHEN f.delivery_days <=  3    THEN '1. 0-3 days'
        WHEN f.delivery_days <=  7    THEN '2. 4-7 days'
        WHEN f.delivery_days <= 14    THEN '3. 8-14 days'
        WHEN f.delivery_days <= 30    THEN '4. 15-30 days'
        ELSE                               '5. 30+ days'
    END AS delivery_speed_band
FROM mart.fact_orders f
JOIN      mart.dim_date         d  ON d.date          = f.purchase_date
JOIN      mart.mv_dim_customer  c  ON c.customer_unique_id = f.customer_unique_id
LEFT JOIN mart.dim_geo          g  ON g.state_code    = f.customer_state_code
LEFT JOIN mart.dim_payment_type pt ON pt.payment_type = f.payment_type;

COMMENT ON VIEW mart.bi_orders IS
    'Superset dataset: one row per order. The only correct place to measure reviews and delivery.';


-- -----------------------------------------------------------------------------
-- bi_customer : ONE ROW PER PERSON. RFM + LTV + geography in a single row.
-- Use for: segment sizes, LTV distribution, concentration, customer tables.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW mart.bi_customer AS
SELECT
    c.customer_unique_id,

    -- geography ----------------------------------------------------------
    c.customer_city,
    c.customer_state,
    c.customer_state_code,
    c.customer_region,
    g.latitude                      AS customer_latitude,
    g.longitude                     AS customer_longitude,

    -- lifecycle ----------------------------------------------------------
    c.first_order_date,
    c.last_order_date,
    c.cohort_month,
    c.cohort_month_label,
    c.lifetime_orders,
    c.is_repeat_customer,

    -- RFM ----------------------------------------------------------------
    r.recency_days,
    r.frequency,
    r.monetary,
    r.r_score,
    r.f_score,
    r.m_score,
    r.fm_score,
    r.rfm_cell,
    r.rfm_segment,
    r.segment_rank,
    r.recommended_action,

    -- LTV ----------------------------------------------------------------
    l.total_orders,
    l.total_items,
    l.product_revenue,
    l.freight_paid,
    l.lifetime_value,
    l.avg_order_value,
    l.avg_review_score,
    l.lifespan_days,
    l.late_deliveries,
    l.revenue_rank,
    l.ltv_decile,
    l.ltv_tier,
    l.ltv_band,
    l.cumulative_revenue_pct,
    l.customer_percentile
FROM mart.mv_dim_customer c
LEFT JOIN mart.mv_rfm          r ON r.customer_unique_id = c.customer_unique_id
LEFT JOIN mart.mv_customer_ltv l ON l.customer_unique_id = c.customer_unique_id
LEFT JOIN mart.dim_geo         g ON g.state_code = c.customer_state_code;

COMMENT ON VIEW mart.bi_customer IS
    'Superset dataset: one row per person, RFM and LTV merged. Customers whose only orders were cancelled have NULL RFM/LTV.';
