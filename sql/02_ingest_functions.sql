-- =============================================================================
-- 02_ingest_functions.sql
-- The drip-ingest engine. n8n schedules and orchestrates; this does the work.
--
-- Why a function instead of 20 n8n nodes: the row-level work is set-based SQL,
-- which belongs in the database where it can be version-controlled, tested and
-- run in a single transaction. n8n owns scheduling, retries, alerting and the
-- error branch. That split is what a real pipeline looks like.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Safe casts. seed.* is all text, so every conversion is a place a bad row can
-- kill a batch. These return NULL instead of raising, and the callers decide
-- whether NULL means "reject" or "acceptable missing value".
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION ops.safe_numeric(p_in text)
RETURNS numeric LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
BEGIN
    IF p_in IS NULL OR btrim(p_in) = '' THEN RETURN NULL; END IF;
    RETURN btrim(p_in)::numeric;
EXCEPTION WHEN others THEN
    RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION ops.safe_int(p_in text)
RETURNS integer LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
BEGIN
    IF p_in IS NULL OR btrim(p_in) = '' THEN RETURN NULL; END IF;
    RETURN round(btrim(p_in)::numeric)::integer;
EXCEPTION WHEN others THEN
    RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION ops.safe_ts(p_in text)
RETURNS timestamp LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
BEGIN
    IF p_in IS NULL OR btrim(p_in) = '' THEN RETURN NULL; END IF;
    RETURN btrim(p_in)::timestamp;
EXCEPTION WHEN others THEN
    RETURN NULL;
END $$;

-- -----------------------------------------------------------------------------
-- Reject logger. Every row that does not make it into raw.* lands here with
-- enough payload to replay it. Silent drops are how pipelines lie to you.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ops.log_reject(
    p_batch_id bigint, p_table text, p_key text,
    p_type text, p_detail text, p_payload jsonb
) RETURNS void LANGUAGE sql AS $$
    INSERT INTO ops.load_errors (batch_id, source_table, record_key, error_type, error_detail, raw_payload)
    VALUES (p_batch_id, p_table, p_key, p_type, p_detail, p_payload);
$$;


-- =============================================================================
-- ops.ingest_next_batch(batch_size)
--
-- Moves the next N orders (by purchase timestamp, tie-broken by order_id) from
-- seed -> raw, together with their items, payments, reviews and customer.
-- Idempotent: re-running after a crash re-reads from the stored watermark and
-- every insert is ON CONFLICT DO NOTHING.
-- =============================================================================
CREATE OR REPLACE FUNCTION ops.ingest_next_batch(p_batch_size integer DEFAULT 500)
RETURNS TABLE (
    batch_id         bigint,
    orders_attempted integer,
    rows_loaded      integer,
    rows_rejected    integer,
    watermark_to     timestamp,
    status           text
)
LANGUAGE plpgsql AS $$
DECLARE
    v_batch      bigint;
    v_wm_ts      timestamp;
    v_wm_id      text;
    v_attempted  integer := 0;
    v_loaded     integer := 0;
    v_rejected   integer := 0;
    v_new_ts     timestamp;
    v_new_id     text;
    v_n          integer;
    v_status     text;
BEGIN
    -- The temp-table guard below raises a harmless NOTICE on every run. Keep the
    -- n8n execution log about the data, not about housekeeping.
    SET LOCAL client_min_messages = warning;

    -- 1. Open the batch -------------------------------------------------------
    --    Take the id from the sequence first: RETURNING ... INTO would collide
    --    with the OUT parameter of the same name.
    v_batch := nextval('ops.load_batch_batch_id_seq');
    INSERT INTO ops.load_batch (batch_id, source_name, notes)
    VALUES (v_batch, 'olist_orders', format('drip batch, size=%s', p_batch_size));

    -- 2. Read the cursor (lock it: two concurrent runs must not grab the same
    --    window). NOWAIT so a second run fails fast instead of piling up.
    SELECT w.last_purchase_ts, coalesce(w.last_order_id, '')
      INTO v_wm_ts, v_wm_id
      FROM ops.ingest_watermark w
     WHERE w.source_name = 'olist_orders'
       FOR UPDATE NOWAIT;

    -- 3. Pick the window ------------------------------------------------------
    DROP TABLE IF EXISTS pg_temp._batch_orders;
    CREATE TEMP TABLE _batch_orders ON COMMIT DROP AS
    SELECT o.order_id,
           ops.safe_ts(o.order_purchase_timestamp) AS purchase_ts,
           o.customer_id,
           o.order_status
      FROM seed.orders o
     WHERE ops.safe_ts(o.order_purchase_timestamp) IS NOT NULL
       AND (ops.safe_ts(o.order_purchase_timestamp), o.order_id) > (v_wm_ts, v_wm_id)
     ORDER BY ops.safe_ts(o.order_purchase_timestamp), o.order_id
     LIMIT p_batch_size;

    SELECT count(*) INTO v_attempted FROM _batch_orders;

    -- Nothing left: close the batch clean and tell the caller the feed is drained.
    IF v_attempted = 0 THEN
        UPDATE ops.load_batch b
           SET finished_at = clock_timestamp(), status = 'succeeded', notes = 'no new orders; source drained'
         WHERE b.batch_id = v_batch;
        RETURN QUERY SELECT v_batch, 0, 0, 0, v_wm_ts, 'succeeded'::text;
        RETURN;
    END IF;

    -- 3b. Orders whose timestamp would not parse never enter the window above,
    --     so log them once, on the first batch, rather than losing them.
    IF v_wm_ts = timestamp '2000-01-01 00:00:00' THEN
        INSERT INTO ops.load_errors (batch_id, source_table, record_key, error_type, error_detail, raw_payload)
        SELECT v_batch, 'seed.orders', o.order_id, 'bad_timestamp',
               'order_purchase_timestamp could not be parsed',
               to_jsonb(o)
          FROM seed.orders o
         WHERE ops.safe_ts(o.order_purchase_timestamp) IS NULL;
        GET DIAGNOSTICS v_n = ROW_COUNT;
        v_rejected := v_rejected + v_n;
    END IF;

    -- 4. Customers (parent of orders, so it goes first) ----------------------
    INSERT INTO raw.customers (customer_id, customer_unique_id, customer_zip_code_prefix,
                               customer_city, customer_state, batch_id)
    SELECT DISTINCT ON (c.customer_id)
           c.customer_id, c.customer_unique_id, c.customer_zip_code_prefix,
           c.customer_city, c.customer_state, v_batch
      FROM seed.customers c
      JOIN _batch_orders b ON b.customer_id = c.customer_id
     WHERE c.customer_unique_id IS NOT NULL
     ORDER BY c.customer_id
    ON CONFLICT (customer_id) DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_loaded := v_loaded + v_n;

    -- Orders pointing at a customer that does not exist in the source: reject.
    PERFORM ops.log_reject(v_batch, 'seed.orders', b.order_id, 'missing_fk',
                           format('customer_id %s not found in seed.customers', b.customer_id),
                           to_jsonb(b))
       FROM _batch_orders b
      WHERE NOT EXISTS (SELECT 1 FROM seed.customers c WHERE c.customer_id = b.customer_id);
    GET DIAGNOSTICS v_n = ROW_COUNT; v_rejected := v_rejected + v_n;

    DELETE FROM _batch_orders b
     WHERE NOT EXISTS (SELECT 1 FROM seed.customers c WHERE c.customer_id = b.customer_id);

    -- 5. Orders ---------------------------------------------------------------
    INSERT INTO raw.orders (order_id, customer_id, order_status, order_purchase_timestamp,
                            order_approved_at, order_delivered_carrier_date,
                            order_delivered_customer_date, order_estimated_delivery_date, batch_id)
    SELECT o.order_id, o.customer_id, lower(btrim(o.order_status)),
           ops.safe_ts(o.order_purchase_timestamp),
           ops.safe_ts(o.order_approved_at),
           ops.safe_ts(o.order_delivered_carrier_date),
           ops.safe_ts(o.order_delivered_customer_date),
           ops.safe_ts(o.order_estimated_delivery_date),
           v_batch
      FROM seed.orders o
      JOIN _batch_orders b ON b.order_id = o.order_id
    ON CONFLICT (order_id) DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_loaded := v_loaded + v_n;

    -- 6. Order items ----------------------------------------------------------
    --    Reject rules: unparseable or negative price/freight, missing product.
    PERFORM ops.log_reject(v_batch, 'seed.order_items',
                           i.order_id || '#' || coalesce(i.order_item_id,'?'),
                           CASE
                             WHEN ops.safe_numeric(i.price) IS NULL THEN 'bad_numeric'
                             WHEN ops.safe_numeric(i.price) < 0    THEN 'negative_price'
                             ELSE 'missing_fk'
                           END,
                           format('price=%s freight=%s product_id=%s', i.price, i.freight_value, i.product_id),
                           to_jsonb(i))
       FROM seed.order_items i
       JOIN _batch_orders b ON b.order_id = i.order_id
      WHERE ops.safe_numeric(i.price) IS NULL
         OR ops.safe_numeric(i.price) < 0
         OR NOT EXISTS (SELECT 1 FROM seed.products p WHERE p.product_id = i.product_id);
    GET DIAGNOSTICS v_n = ROW_COUNT; v_rejected := v_rejected + v_n;

    INSERT INTO raw.order_items (order_id, order_item_id, product_id, seller_id,
                                 shipping_limit_date, price, freight_value, batch_id)
    SELECT DISTINCT ON (i.order_id, ops.safe_int(i.order_item_id))
           i.order_id,
           ops.safe_int(i.order_item_id),
           i.product_id,
           i.seller_id,
           ops.safe_ts(i.shipping_limit_date),
           ops.safe_numeric(i.price),
           -- freight is genuinely absent on a handful of rows; 0 is the correct
           -- business reading (free shipping), so this is a fill, not a reject.
           coalesce(ops.safe_numeric(i.freight_value), 0),
           v_batch
      FROM seed.order_items i
      JOIN _batch_orders b ON b.order_id = i.order_id
     WHERE ops.safe_numeric(i.price) IS NOT NULL
       AND ops.safe_numeric(i.price) >= 0
       AND ops.safe_int(i.order_item_id) IS NOT NULL
       AND EXISTS (SELECT 1 FROM seed.products p WHERE p.product_id = i.product_id)
     ORDER BY i.order_id, ops.safe_int(i.order_item_id)
    ON CONFLICT (order_id, order_item_id) DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_loaded := v_loaded + v_n;

    -- 7. Payments -------------------------------------------------------------
    PERFORM ops.log_reject(v_batch, 'seed.order_payments',
                           p.order_id || '#' || coalesce(p.payment_sequential,'?'),
                           'bad_numeric',
                           format('payment_value=%s installments=%s', p.payment_value, p.payment_installments),
                           to_jsonb(p))
       FROM seed.order_payments p
       JOIN _batch_orders b ON b.order_id = p.order_id
      WHERE ops.safe_numeric(p.payment_value) IS NULL
         OR ops.safe_int(p.payment_sequential) IS NULL;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_rejected := v_rejected + v_n;

    INSERT INTO raw.order_payments (order_id, payment_sequential, payment_type,
                                    payment_installments, payment_value, batch_id)
    SELECT DISTINCT ON (p.order_id, ops.safe_int(p.payment_sequential))
           p.order_id,
           ops.safe_int(p.payment_sequential),
           lower(btrim(p.payment_type)),
           coalesce(ops.safe_int(p.payment_installments), 1),
           ops.safe_numeric(p.payment_value),
           v_batch
      FROM seed.order_payments p
      JOIN _batch_orders b ON b.order_id = p.order_id
     WHERE ops.safe_numeric(p.payment_value) IS NOT NULL
       AND ops.safe_int(p.payment_sequential) IS NOT NULL
     ORDER BY p.order_id, ops.safe_int(p.payment_sequential)
    ON CONFLICT (order_id, payment_sequential) DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_loaded := v_loaded + v_n;

    -- 8. Reviews --------------------------------------------------------------
    --    The source has ~800 review_ids attached to more than one order and a
    --    handful of exact duplicate rows. PK (review_id, order_id) + DISTINCT ON
    --    keeps the most recently created row for each pair.
    PERFORM ops.log_reject(v_batch, 'seed.order_reviews', r.review_id, 'bad_score',
                           format('review_score=%s', r.review_score), to_jsonb(r))
       FROM seed.order_reviews r
       JOIN _batch_orders b ON b.order_id = r.order_id
      WHERE ops.safe_int(r.review_score) IS NULL
         OR ops.safe_int(r.review_score) NOT BETWEEN 1 AND 5;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_rejected := v_rejected + v_n;

    INSERT INTO raw.order_reviews (review_id, order_id, review_score, has_comment,
                                   comment_length, review_creation_date,
                                   review_answer_timestamp, batch_id)
    SELECT DISTINCT ON (r.review_id, r.order_id)
           r.review_id,
           r.order_id,
           ops.safe_int(r.review_score)::smallint,
           (r.review_comment_message IS NOT NULL AND btrim(r.review_comment_message) <> ''),
           coalesce(length(btrim(r.review_comment_message)), 0),
           ops.safe_ts(r.review_creation_date),
           ops.safe_ts(r.review_answer_timestamp),
           v_batch
      FROM seed.order_reviews r
      JOIN _batch_orders b ON b.order_id = r.order_id
     WHERE ops.safe_int(r.review_score) BETWEEN 1 AND 5
     ORDER BY r.review_id, r.order_id, ops.safe_ts(r.review_creation_date) DESC NULLS LAST
    ON CONFLICT (review_id, order_id) DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_loaded := v_loaded + v_n;

    -- 9. Advance the cursor ---------------------------------------------------
    SELECT b.purchase_ts, b.order_id INTO v_new_ts, v_new_id
      FROM _batch_orders b
     ORDER BY b.purchase_ts DESC, b.order_id DESC
     LIMIT 1;

    UPDATE ops.ingest_watermark w
       SET last_purchase_ts = v_new_ts,
           last_order_id    = v_new_id,
           orders_ingested  = w.orders_ingested + v_attempted,
           updated_at       = now()
     WHERE w.source_name = 'olist_orders';

    -- 10. Close the batch -----------------------------------------------------
    v_status := CASE WHEN v_rejected > 0 THEN 'partial' ELSE 'succeeded' END;

    UPDATE ops.load_batch b
       SET finished_at      = clock_timestamp(),
           status           = v_status,
           orders_attempted = v_attempted,
           rows_loaded      = v_loaded,
           rows_rejected    = v_rejected,
           watermark_from   = v_wm_ts,
           watermark_to     = v_new_ts
     WHERE b.batch_id = v_batch;

    RETURN QUERY SELECT v_batch, v_attempted, v_loaded, v_rejected, v_new_ts, v_status;
END $$;

COMMENT ON FUNCTION ops.ingest_next_batch(integer) IS
    'Moves the next N orders from seed to raw with validation and reject logging. Idempotent, watermark-driven.';


-- =============================================================================
-- Indexes on seed.* -- these are what make the drip cheap.
--
-- Without them every batch is O(all source rows): the window query calls
-- safe_ts() across all 99k orders and sorts them just to take 1000, and each
-- child join full-scans 100k+ rows. Measured on Neon that was ~20s per batch,
-- so ~35 minutes to drain the feed. With them a batch is an index range scan
-- plus the joins, and the same drain takes a couple of minutes.
--
-- The functional index works because safe_ts is declared IMMUTABLE -- it is
-- deterministic, it just swallows the cast error instead of raising.
--
-- Created here rather than in 01 because they reference ops.safe_ts, which is
-- defined above. The tables are still empty at this point, so the build is free
-- and COPY maintains them during the seed load.
-- =============================================================================

CREATE INDEX IF NOT EXISTS ix_seed_orders_purchase_ts
    ON seed.orders (ops.safe_ts(order_purchase_timestamp), order_id);

CREATE INDEX IF NOT EXISTS ix_seed_orders_customer   ON seed.orders (customer_id);
CREATE INDEX IF NOT EXISTS ix_seed_customers_id      ON seed.customers (customer_id);
CREATE INDEX IF NOT EXISTS ix_seed_items_order       ON seed.order_items (order_id);
CREATE INDEX IF NOT EXISTS ix_seed_payments_order    ON seed.order_payments (order_id);
CREATE INDEX IF NOT EXISTS ix_seed_reviews_order     ON seed.order_reviews (order_id);
CREATE INDEX IF NOT EXISTS ix_seed_products_id       ON seed.products (product_id);
