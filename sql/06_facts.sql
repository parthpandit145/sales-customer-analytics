-- =============================================================================
-- 06_facts.sql
-- Two fact views at two grains. This is deliberate, not redundant.
--
--   mart.fact_sales  -- one row per ORDER ITEM. Product, seller, price, freight.
--   mart.fact_orders -- one row per ORDER.      Review, delivery, payment, AOV.
--
-- Why two: review_score and delivery_days are properties of an ORDER. Carrying
-- them on the item grain and averaging them silently weights every order by how
-- many items it contained, so a 5-item order counts five times in "average
-- review score". Splitting the grains is the fix. Both facts share the same
-- dimensions, so slicers filter them together.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Order sequence per customer -- powers new-vs-returning and first-order cohorts.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW stg.order_sequence AS
SELECT
    o.order_id,
    c.customer_unique_id,
    row_number() OVER (PARTITION BY c.customer_unique_id
                       ORDER BY o.purchase_ts, o.order_id) AS order_seq
FROM stg.orders o
JOIN stg.customers c ON c.customer_id = o.customer_id;

-- =============================================================================
-- fact_sales : order-item grain
-- =============================================================================
CREATE OR REPLACE VIEW mart.fact_sales AS
WITH item_context AS (
    SELECT
        i.*,
        sum(i.item_total) OVER (PARTITION BY i.order_id) AS order_item_total,
        count(*)          OVER (PARTITION BY i.order_id) AS items_in_order
    FROM stg.order_items i
)
SELECT
    -- keys ---------------------------------------------------------------
    i.order_id || '-' || i.order_item_id            AS order_item_key,
    i.order_id,
    i.order_item_id,
    c.customer_unique_id,
    o.customer_id,
    i.product_id,
    i.seller_id,
    o.purchase_date,
    to_char(o.purchase_date, 'YYYYMMDD')::int       AS date_key,
    o.delivered_ts::date                            AS delivered_date,
    c.state_code                                    AS customer_state_code,
    coalesce(ps.primary_payment_type, 'unknown')    AS payment_type,

    -- order context ------------------------------------------------------
    o.order_status,
    o.is_delivered,
    (o.order_status NOT IN ('canceled','unavailable')) AS is_valid_sale,
    i.items_in_order,
    seq.order_seq,
    (seq.order_seq = 1)                             AS is_first_order,

    -- measures -----------------------------------------------------------
    i.price,
    i.freight_value,
    i.item_total,
    i.freight_ratio,
    -- Payment is recorded per order, not per item. Allocate it down to the item
    -- in proportion to that item's share of the order value. Vouchers and
    -- rounding mean payment_total does not always equal item_total -- both are
    -- exposed so the difference stays visible instead of being papered over.
    round(coalesce(ps.payment_total, i.order_item_total)
          * (i.item_total / nullif(i.order_item_total, 0)), 2) AS allocated_payment,
    coalesce(ps.primary_installments, 1)            AS installments,

    -- order-level attributes carried for filtering only. Do NOT average these
    -- at this grain; use fact_orders. Named with an _oa suffix as a reminder.
    r.review_score                                  AS review_score_oa,
    r.review_band                                   AS review_band_oa
FROM item_context i
JOIN stg.orders        o   ON o.order_id  = i.order_id
JOIN stg.customers     c   ON c.customer_id = o.customer_id
JOIN stg.order_sequence seq ON seq.order_id = o.order_id
LEFT JOIN stg.order_payment_summary ps ON ps.order_id = i.order_id
LEFT JOIN stg.order_reviews         r  ON r.order_id  = i.order_id;

COMMENT ON VIEW mart.fact_sales IS
    'Order-item grain. Revenue, freight, product and seller analysis. Filter with is_valid_sale.';


-- =============================================================================
-- fact_orders : order grain
-- =============================================================================
CREATE OR REPLACE VIEW mart.fact_orders AS
WITH item_rollup AS (
    SELECT
        i.order_id,
        count(*)                        AS items_in_order,
        count(DISTINCT i.product_id)    AS distinct_products,
        count(DISTINCT i.seller_id)     AS distinct_sellers,
        sum(i.price)                    AS order_revenue,
        sum(i.freight_value)            AS order_freight,
        sum(i.item_total)               AS order_total
    FROM stg.order_items i
    GROUP BY i.order_id
)
SELECT
    -- keys ---------------------------------------------------------------
    o.order_id,
    c.customer_unique_id,
    o.customer_id,
    o.purchase_date,
    to_char(o.purchase_date, 'YYYYMMDD')::int       AS date_key,
    o.delivered_ts::date                            AS delivered_date,
    c.state_code                                    AS customer_state_code,
    coalesce(ps.primary_payment_type, 'unknown')    AS payment_type,

    -- status -------------------------------------------------------------
    o.order_status,
    o.is_delivered,
    o.is_cancelled,
    (o.order_status NOT IN ('canceled','unavailable')) AS is_valid_sale,

    -- customer context ---------------------------------------------------
    seq.order_seq,
    (seq.order_seq = 1)                             AS is_first_order,
    CASE WHEN seq.order_seq = 1 THEN 'New' ELSE 'Returning' END AS customer_type,

    -- basket -------------------------------------------------------------
    coalesce(ir.items_in_order, 0)                  AS items_in_order,
    coalesce(ir.distinct_products, 0)               AS distinct_products,
    coalesce(ir.distinct_sellers, 0)                AS distinct_sellers,
    coalesce(ir.order_revenue, 0)                   AS order_revenue,
    coalesce(ir.order_freight, 0)                   AS order_freight,
    coalesce(ir.order_total, 0)                     AS order_total,

    -- payment ------------------------------------------------------------
    ps.payment_total,
    ps.payment_method_count,
    coalesce(ps.primary_installments, 1)            AS installments,
    -- reconciliation gap: payments minus items. Non-zero means vouchers or
    -- rounding. Charting this is a fast credibility check on the model.
    round(coalesce(ps.payment_total, 0) - coalesce(ir.order_total, 0), 2) AS payment_gap,

    -- experience ---------------------------------------------------------
    r.review_score,
    r.review_band,
    r.has_comment,
    r.comment_length,
    o.approval_hours,
    o.delivery_days,
    o.promised_days,
    o.days_vs_promise,
    o.is_late
FROM stg.orders o
JOIN stg.customers      c   ON c.customer_id = o.customer_id
JOIN stg.order_sequence seq ON seq.order_id  = o.order_id
LEFT JOIN item_rollup   ir  ON ir.order_id   = o.order_id
LEFT JOIN stg.order_payment_summary ps ON ps.order_id = o.order_id
LEFT JOIN stg.order_reviews         r  ON r.order_id  = o.order_id;

COMMENT ON VIEW mart.fact_orders IS
    'Order grain. AOV, review score, delivery performance, new vs returning.';
