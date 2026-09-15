-- =============================================================================
-- 03_staging.sql
-- The cleaning layer. Types, trimming, casing, accents, dedupe, null policy.
-- No business logic lives here -- that is 04/05/06.
--
-- This is the file that replaces Power Query. Everything a Power Query author
-- would do in the M editor happens below, in SQL, upstream of Power BI.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Reference: Brazilian states -> full name + macro region.
-- Power BI's map visual resolves "Sao Paulo, Brazil" far more reliably than the
-- two-letter code, so the dimension carries both.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stg.br_state (
    state_code text PRIMARY KEY,
    state_name text NOT NULL,
    region     text NOT NULL
);

TRUNCATE stg.br_state;
INSERT INTO stg.br_state (state_code, state_name, region) VALUES
 ('AC','Acre','North'),                ('AL','Alagoas','Northeast'),
 ('AP','Amapa','North'),               ('AM','Amazonas','North'),
 ('BA','Bahia','Northeast'),           ('CE','Ceara','Northeast'),
 ('DF','Distrito Federal','Central-West'), ('ES','Espirito Santo','Southeast'),
 ('GO','Goias','Central-West'),        ('MA','Maranhao','Northeast'),
 ('MT','Mato Grosso','Central-West'),  ('MS','Mato Grosso do Sul','Central-West'),
 ('MG','Minas Gerais','Southeast'),    ('PA','Para','North'),
 ('PB','Paraiba','Northeast'),         ('PR','Parana','South'),
 ('PE','Pernambuco','Northeast'),      ('PI','Piaui','Northeast'),
 ('RJ','Rio de Janeiro','Southeast'),  ('RN','Rio Grande do Norte','Northeast'),
 ('RS','Rio Grande do Sul','South'),   ('RO','Rondonia','North'),
 ('RR','Roraima','North'),             ('SC','Santa Catarina','South'),
 ('SP','Sao Paulo','Southeast'),       ('SE','Sergipe','Northeast'),
 ('TO','Tocantins','North');

-- -----------------------------------------------------------------------------
-- Reference: 74 leaf categories -> 11 reportable groups.
-- The leaf list is too long for a chart axis and too noisy for a Pareto, so the
-- model carries both grains and the report drills leaf <- group.
-- Note the source typos preserved as keys: costruction_tools_*, fashio_female_*,
-- home_confort. Fixing them silently would break the join.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stg.category_group_map (
    category_en    text PRIMARY KEY,
    category_group text NOT NULL
);

TRUNCATE stg.category_group_map;
INSERT INTO stg.category_group_map (category_en, category_group) VALUES
 ('bed_bath_table','Home & Furniture'), ('furniture_decor','Home & Furniture'),
 ('housewares','Home & Furniture'),     ('office_furniture','Home & Furniture'),
 ('kitchen_dining_laundry_garden_furniture','Home & Furniture'),
 ('furniture_mattress_and_upholstery','Home & Furniture'),
 ('furniture_living_room','Home & Furniture'), ('furniture_bedroom','Home & Furniture'),
 ('home_confort','Home & Furniture'),   ('home_comfort_2','Home & Furniture'),
 ('la_cuisine','Home & Furniture'),     ('flowers','Home & Furniture'),
 ('christmas_supplies','Home & Furniture'), ('party_supplies','Home & Furniture'),
 ('art','Home & Furniture'),            ('arts_and_craftmanship','Home & Furniture'),

 ('computers_accessories','Electronics & Computing'), ('computers','Electronics & Computing'),
 ('electronics','Electronics & Computing'),           ('tablets_printing_image','Electronics & Computing'),
 ('audio','Electronics & Computing'),                 ('consoles_games','Electronics & Computing'),
 ('cine_photo','Electronics & Computing'),            ('pc_gamer','Electronics & Computing'),
 ('telephony','Electronics & Computing'),             ('fixed_telephony','Electronics & Computing'),

 ('home_appliances','Home Appliances'),   ('home_appliances_2','Home Appliances'),
 ('small_appliances','Home Appliances'),  ('air_conditioning','Home Appliances'),
 ('small_appliances_home_oven_and_coffee','Home Appliances'),
 ('portateis_cozinha_e_preparadores_de_alimentos','Home Appliances'),

 ('health_beauty','Health & Beauty'), ('perfumery','Health & Beauty'),
 ('diapers_and_hygiene','Health & Beauty'),

 ('fashion_bags_accessories','Fashion & Accessories'), ('fashion_shoes','Fashion & Accessories'),
 ('fashion_male_clothing','Fashion & Accessories'),    ('fashio_female_clothing','Fashion & Accessories'),
 ('fashion_underwear_beach','Fashion & Accessories'),  ('fashion_sport','Fashion & Accessories'),
 ('fashion_childrens_clothes','Fashion & Accessories'),('luggage_accessories','Fashion & Accessories'),
 ('watches_gifts','Fashion & Accessories'),

 ('sports_leisure','Sports, Toys & Leisure'), ('toys','Sports, Toys & Leisure'),
 ('baby','Sports, Toys & Leisure'),           ('musical_instruments','Sports, Toys & Leisure'),
 ('music','Sports, Toys & Leisure'),          ('cds_dvds_musicals','Sports, Toys & Leisure'),
 ('dvds_blu_ray','Sports, Toys & Leisure'),

 ('construction_tools_construction','Tools & Construction'),
 ('costruction_tools_garden','Tools & Construction'),
 ('costruction_tools_tools','Tools & Construction'),
 ('construction_tools_lights','Tools & Construction'),
 ('construction_tools_safety','Tools & Construction'),
 ('garden_tools','Tools & Construction'), ('home_construction','Tools & Construction'),
 ('signaling_and_security','Tools & Construction'), ('security_and_services','Tools & Construction'),

 ('books_technical','Books & Stationery'), ('books_general_interest','Books & Stationery'),
 ('books_imported','Books & Stationery'),  ('stationery','Books & Stationery'),

 ('food_drink','Food & Drink'), ('food','Food & Drink'), ('drinks','Food & Drink'),

 ('auto','Auto & Industrial'), ('agro_industry_and_commerce','Auto & Industrial'),
 ('industry_commerce_and_business','Auto & Industrial'),

 ('pet_shop','Other'), ('cool_stuff','Other'), ('market_place','Other');


-- =============================================================================
-- CLEANING VIEWS
-- =============================================================================

-- Text normaliser used everywhere: strip accents, collapse whitespace, title case.
-- "SÃO  PAULO " -> "Sao Paulo"
--
-- unaccent is schema-qualified on purpose. CREATE INDEX, REFRESH MATERIALIZED
-- VIEW and friends run with a locked-down search_path (a security measure
-- against search_path hijacking), so an unqualified call that works perfectly
-- in an ordinary query fails with "function unaccent(text) does not exist" the
-- moment it is reached from a maintenance command. Qualifying is preferable to
-- attaching SET search_path to the function, which would block inlining.
--
CREATE OR REPLACE FUNCTION stg.clean_place(p_in text)
RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT nullif(initcap(regexp_replace(public.unaccent(btrim(lower(p_in))), '\s+', ' ', 'g')), '');
$$;

-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW stg.customers AS
SELECT
    c.customer_id,
    c.customer_unique_id,
    -- zip prefixes lose their leading zero when the CSV is read as a number
    lpad(btrim(c.customer_zip_code_prefix), 5, '0') AS zip_code_prefix,
    stg.clean_place(c.customer_city)                AS city,
    upper(btrim(c.customer_state))                  AS state_code
FROM raw.customers c;

COMMENT ON VIEW stg.customers IS
    'One row per customer_id (which in Olist is per-ORDER). customer_unique_id is the real person.';

-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW stg.orders AS
SELECT
    o.order_id,
    o.customer_id,
    o.order_status,
    o.order_purchase_timestamp                          AS purchase_ts,
    o.order_purchase_timestamp::date                    AS purchase_date,
    o.order_approved_at                                 AS approved_ts,
    o.order_delivered_carrier_date                      AS shipped_ts,
    o.order_delivered_customer_date                     AS delivered_ts,
    o.order_estimated_delivery_date                     AS estimated_delivery_ts,

    (o.order_status = 'delivered')                      AS is_delivered,
    (o.order_status IN ('canceled','unavailable'))      AS is_cancelled,

    -- Fulfilment metrics. NULL where the milestone never happened, which is the
    -- honest answer -- do not coalesce these to 0, it flatters the averages.
    round(extract(epoch FROM (o.order_approved_at - o.order_purchase_timestamp)) / 3600.0, 2)
        AS approval_hours,
    (o.order_delivered_customer_date::date - o.order_purchase_timestamp::date)
        AS delivery_days,
    (o.order_estimated_delivery_date::date - o.order_purchase_timestamp::date)
        AS promised_days,
    (o.order_delivered_customer_date::date - o.order_estimated_delivery_date::date)
        AS days_vs_promise,
    CASE
        WHEN o.order_delivered_customer_date IS NULL THEN NULL
        ELSE o.order_delivered_customer_date > o.order_estimated_delivery_date
    END AS is_late
FROM raw.orders o;

-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW stg.order_items AS
SELECT
    i.order_id,
    i.order_item_id,
    i.product_id,
    i.seller_id,
    i.shipping_limit_date,
    i.price,
    i.freight_value,
    (i.price + i.freight_value)                                    AS item_total,
    CASE WHEN i.price > 0
         THEN round(i.freight_value / i.price, 4) END              AS freight_ratio
FROM raw.order_items i;

-- -----------------------------------------------------------------------------
-- Payments arrive one row per instalment plan per order. The fact table needs
-- one number per order, so summarise here and keep the detail view for the
-- payment-mix visual.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW stg.order_payments AS
SELECT
    p.order_id,
    p.payment_sequential,
    p.payment_type,
    p.payment_installments,
    p.payment_value
FROM raw.order_payments p
WHERE p.payment_type <> 'not_defined';   -- 3 rows in the source, all zero-value

CREATE OR REPLACE VIEW stg.order_payment_summary AS
WITH ranked AS (
    SELECT
        p.order_id,
        p.payment_type,
        p.payment_value,
        p.payment_installments,
        row_number() OVER (PARTITION BY p.order_id
                           ORDER BY p.payment_value DESC, p.payment_sequential) AS rn
    FROM stg.order_payments p
)
SELECT
    p.order_id,
    sum(p.payment_value)                       AS payment_total,
    count(*)                                   AS payment_line_count,
    count(DISTINCT p.payment_type)             AS payment_method_count,
    max(p.payment_installments)                AS max_installments,
    -- "primary" = the method that carried the most money on the order
    max(r.payment_type)     FILTER (WHERE r.rn = 1) AS primary_payment_type,
    max(r.payment_installments) FILTER (WHERE r.rn = 1) AS primary_installments
FROM stg.order_payments p
JOIN ranked r ON r.order_id = p.order_id
GROUP BY p.order_id;

-- -----------------------------------------------------------------------------
-- One review per order: keep the most recent. ~550 orders carry two reviews.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW stg.order_reviews AS
SELECT DISTINCT ON (r.order_id)
    r.order_id,
    r.review_id,
    r.review_score,
    r.has_comment,
    r.comment_length,
    r.review_creation_date,
    (r.review_answer_timestamp::date - r.review_creation_date::date) AS response_days,
    CASE
        WHEN r.review_score >= 4 THEN 'Promoter (4-5)'
        WHEN r.review_score  = 3 THEN 'Passive (3)'
        ELSE                          'Detractor (1-2)'
    END AS review_band
FROM raw.order_reviews r
ORDER BY r.order_id, r.review_creation_date DESC NULLS LAST, r.review_id;

-- -----------------------------------------------------------------------------
-- Products. This is where the Portuguese category names get resolved.
-- 610 products have no category at all, and two categories are missing from
-- Olist's own translation file (pc_gamer, portateis_cozinha...). Both are
-- handled explicitly rather than dropped.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW stg.products AS
WITH base AS (
    SELECT
        p.product_id,
        nullif(btrim(lower(p.product_category_name)), '')   AS category_pt,
        ops.safe_int(p.product_name_lenght)                 AS name_length,
        ops.safe_int(p.product_description_lenght)          AS description_length,
        coalesce(ops.safe_int(p.product_photos_qty), 0)     AS photos_qty,
        ops.safe_numeric(p.product_weight_g)                AS weight_g,
        ops.safe_numeric(p.product_length_cm)               AS length_cm,
        ops.safe_numeric(p.product_height_cm)               AS height_cm,
        ops.safe_numeric(p.product_width_cm)                AS width_cm
    FROM seed.products p
)
SELECT
    b.product_id,
    b.category_pt,
    -- translation file first, then the two known gaps, then fall back to the
    -- Portuguese key so nothing silently becomes NULL
    coalesce(t.product_category_name_english, b.category_pt, 'unknown') AS category_key,
    initcap(replace(
        coalesce(t.product_category_name_english, b.category_pt, 'unknown'), '_', ' '
    )) AS category_en,
    coalesce(g.category_group, 'Other') AS category_group,
    b.name_length,
    b.description_length,
    b.photos_qty,
    b.weight_g,
    b.length_cm, b.height_cm, b.width_cm,
    CASE WHEN b.length_cm IS NOT NULL AND b.height_cm IS NOT NULL AND b.width_cm IS NOT NULL
         THEN round(b.length_cm * b.height_cm * b.width_cm, 1) END AS volume_cm3
FROM base b
LEFT JOIN seed.category_translation t
       ON lower(btrim(t.product_category_name)) = b.category_pt
LEFT JOIN stg.category_group_map g
       ON g.category_en = coalesce(t.product_category_name_english, b.category_pt);

-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW stg.sellers AS
SELECT
    s.seller_id,
    lpad(btrim(s.seller_zip_code_prefix), 5, '0') AS zip_code_prefix,
    stg.clean_place(s.seller_city)                AS city,
    upper(btrim(s.seller_state))                  AS state_code
FROM seed.sellers s;

-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW stg.geolocation AS
SELECT
    lpad(btrim(g.zip_code_prefix), 5, '0') AS zip_code_prefix,
    g.lat,
    g.lng,
    stg.clean_place(g.city)                AS city,
    upper(btrim(g.state))                  AS state_code,
    g.sample_count
FROM seed.geolocation g
-- a few hundred points sit outside Brazil's bounding box (bad GPS samples)
WHERE g.lat BETWEEN -34.0 AND  5.5
  AND g.lng BETWEEN -74.0 AND -34.0;
