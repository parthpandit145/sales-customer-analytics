-- =============================================================================
-- 01_tables_seed_raw_ops.sql
-- Physical tables: seed (source), raw (landing), ops (telemetry).
-- Run after 00_schemas.sql.
--
-- Every table here is CREATE TABLE IF NOT EXISTS, never DROP-then-CREATE. This
-- file has to be safe to re-run against a populated database: dropping raw.*
-- would silently destroy everything the pipeline has ingested and reset the
-- watermark, so a routine "let me just re-apply the schema" would cost you the
-- whole load. To deliberately wipe, run sql/99_reset.sql -- it says what it is.
--
-- Trade-off: because these are IF NOT EXISTS, changing a column definition here
-- will NOT alter an existing table. Add an ALTER, or reset explicitly.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- SEED : mirrors the Olist CSVs exactly. Everything is text on purpose --
-- a landing table that refuses bad rows is a landing table that loses data.
-- Typing happens in stg.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS seed.customers (
    customer_id               text,
    customer_unique_id        text,
    customer_zip_code_prefix  text,
    customer_city             text,
    customer_state            text
);

CREATE TABLE IF NOT EXISTS seed.orders (
    order_id                       text,
    customer_id                    text,
    order_status                   text,
    order_purchase_timestamp       text,
    order_approved_at              text,
    order_delivered_carrier_date   text,
    order_delivered_customer_date  text,
    order_estimated_delivery_date  text
);

CREATE TABLE IF NOT EXISTS seed.order_items (
    order_id             text,
    order_item_id        text,
    product_id           text,
    seller_id            text,
    shipping_limit_date  text,
    price                text,
    freight_value        text
);

CREATE TABLE IF NOT EXISTS seed.order_payments (
    order_id              text,
    payment_sequential    text,
    payment_type          text,
    payment_installments  text,
    payment_value         text
);

-- NOTE: review_comment_message is deliberately NOT carried past the CSV load.
-- On Neon's 0.5 GB free tier the Portuguese comment bodies are ~35 MB per copy
-- and we only ever use the score. 06_reviews in the loader keeps the *length*
-- instead, which is enough for a "do unhappy customers write more?" cut.
CREATE TABLE IF NOT EXISTS seed.order_reviews (
    review_id                text,
    order_id                 text,
    review_score             text,
    review_comment_title     text,
    review_comment_message   text,
    review_creation_date     text,
    review_answer_timestamp  text
);

CREATE TABLE IF NOT EXISTS seed.products (
    product_id                  text,
    product_category_name       text,
    product_name_lenght         text,   -- [sic] the source really is misspelled
    product_description_lenght  text,   -- [sic]
    product_photos_qty          text,
    product_weight_g            text,
    product_length_cm           text,
    product_height_cm           text,
    product_width_cm            text
);

CREATE TABLE IF NOT EXISTS seed.sellers (
    seller_id                text,
    seller_zip_code_prefix   text,
    seller_city              text,
    seller_state             text
);

CREATE TABLE IF NOT EXISTS seed.category_translation (
    product_category_name          text,
    product_category_name_english  text
);

-- Geolocation ships as ~1M rows (one per address sample). We never need that
-- grain -- one representative point per zip prefix is all the map uses -- and
-- the raw table alone would eat a fifth of the free tier. The loader lands it
-- in a staging table, aggregates, then drops the staging table.
CREATE TABLE IF NOT EXISTS seed.geolocation (
    zip_code_prefix  text PRIMARY KEY,
    lat              numeric(10,6),
    lng              numeric(10,6),
    city             text,
    state            text,
    sample_count     integer
);


-- -----------------------------------------------------------------------------
-- RAW : what n8n actually writes. Same shape as seed, plus lineage columns.
-- Append-only; the pipeline is idempotent via the natural-key constraints.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS raw.orders (
    order_id                       text PRIMARY KEY,
    customer_id                    text,
    order_status                   text,
    order_purchase_timestamp       timestamp,
    order_approved_at              timestamp,
    order_delivered_carrier_date   timestamp,
    order_delivered_customer_date  timestamp,
    order_estimated_delivery_date  timestamp,
    batch_id                       bigint,
    ingested_at                    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS raw.order_items (
    order_id             text,
    order_item_id        integer,
    product_id           text,
    seller_id            text,
    shipping_limit_date  timestamp,
    price                numeric(12,2),
    freight_value        numeric(12,2),
    batch_id             bigint,
    ingested_at          timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (order_id, order_item_id)
);

CREATE TABLE IF NOT EXISTS raw.order_payments (
    order_id              text,
    payment_sequential    integer,
    payment_type          text,
    payment_installments  integer,
    payment_value         numeric(12,2),
    batch_id              bigint,
    ingested_at           timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (order_id, payment_sequential)
);

CREATE TABLE IF NOT EXISTS raw.order_reviews (
    review_id                text,
    order_id                 text,
    review_score             smallint,
    has_comment              boolean,
    comment_length           integer,
    review_creation_date     timestamp,
    review_answer_timestamp  timestamp,
    batch_id                 bigint,
    ingested_at              timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (review_id, order_id)
);

CREATE TABLE IF NOT EXISTS raw.customers (
    customer_id               text PRIMARY KEY,
    customer_unique_id        text,
    customer_zip_code_prefix  text,
    customer_city             text,
    customer_state            text,
    batch_id                  bigint,
    ingested_at               timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_raw_orders_purchase  ON raw.orders (order_purchase_timestamp);
CREATE INDEX IF NOT EXISTS ix_raw_orders_customer  ON raw.orders (customer_id);
CREATE INDEX IF NOT EXISTS ix_raw_items_product    ON raw.order_items (product_id);
CREATE INDEX IF NOT EXISTS ix_raw_cust_unique      ON raw.customers (customer_unique_id);


-- -----------------------------------------------------------------------------
-- OPS : pipeline telemetry.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS ops.load_batch (
    batch_id        bigserial PRIMARY KEY,
    source_name     text        NOT NULL,
    -- clock_timestamp(), not now(): now() is the TRANSACTION start time and is
    -- constant for the whole function call, so started_at and finished_at would
    -- be identical and every batch would report a duration of exactly zero.
    started_at      timestamptz NOT NULL DEFAULT clock_timestamp(),
    finished_at     timestamptz,
    status          text        NOT NULL DEFAULT 'running'
                    CHECK (status IN ('running','succeeded','failed','partial')),
    orders_attempted integer    NOT NULL DEFAULT 0,
    rows_loaded      integer    NOT NULL DEFAULT 0,
    rows_rejected    integer    NOT NULL DEFAULT 0,
    watermark_from   timestamp,
    watermark_to     timestamp,
    notes            text
);

CREATE TABLE IF NOT EXISTS ops.load_errors (
    error_id      bigserial PRIMARY KEY,
    batch_id      bigint REFERENCES ops.load_batch(batch_id),
    source_table  text        NOT NULL,
    record_key    text,
    error_type    text        NOT NULL,   -- e.g. missing_fk, bad_numeric, null_required
    error_detail  text,
    raw_payload   jsonb,
    logged_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_load_errors_batch ON ops.load_errors (batch_id);
CREATE INDEX IF NOT EXISTS ix_load_errors_type  ON ops.load_errors (error_type);

-- Single-row-per-source cursor so the drip job is resumable and idempotent.
CREATE TABLE IF NOT EXISTS ops.ingest_watermark (
    source_name       text PRIMARY KEY,
    last_purchase_ts  timestamp   NOT NULL,
    last_order_id     text,
    orders_ingested   bigint      NOT NULL DEFAULT 0,
    updated_at        timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ops.dq_result (
    dq_id       bigserial PRIMARY KEY,
    batch_id    bigint REFERENCES ops.load_batch(batch_id),
    check_name  text        NOT NULL,
    severity    text        NOT NULL CHECK (severity IN ('error','warn','info')),
    status      text        NOT NULL CHECK (status IN ('pass','fail')),
    observed    numeric,
    threshold   numeric,
    detail      text,
    checked_at  timestamptz NOT NULL DEFAULT now()
);

-- Start the cursor before the earliest Olist order so the first run picks up
-- from the beginning of time.
INSERT INTO ops.ingest_watermark (source_name, last_purchase_ts, orders_ingested)
VALUES ('olist_orders', timestamp '2000-01-01 00:00:00', 0)
ON CONFLICT (source_name) DO NOTHING;
