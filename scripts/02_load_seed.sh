#!/usr/bin/env bash
# Bulk-loads the nine Olist CSVs into the seed schema -- the "source system"
# the n8n pipeline then drips out of.
#
# Geolocation is special-cased: it ships as ~1M address samples and we only need
# one representative point per zip prefix. It lands in a staging table, gets
# aggregated to the median lat/lng per prefix, and the staging table is dropped.
# On Neon's 0.5 GB free tier that difference is roughly 90 MB.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/_common.sh
: "${DATABASE_URL:?set DATABASE_URL in scripts/.env}"
DATA_DIR="${DATA_DIR:-./data}"

need() { [ -f "$DATA_DIR/$1" ] || { echo "missing $DATA_DIR/$1 -- run scripts/00_download_data.sh" >&2; exit 1; }; }
for f in olist_customers_dataset.csv olist_orders_dataset.csv olist_order_items_dataset.csv \
         olist_order_payments_dataset.csv olist_order_reviews_dataset.csv \
         olist_products_dataset.csv olist_sellers_dataset.csv \
         olist_geolocation_dataset.csv product_category_name_translation.csv; do need "$f"; done

echo ">> truncating seed"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q -c "
  TRUNCATE seed.customers, seed.orders, seed.order_items, seed.order_payments,
           seed.order_reviews, seed.products, seed.sellers,
           seed.category_translation, seed.geolocation;"

copy_csv () {  # $1 = table, $2 = file
  echo ">> $1"
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q \
    -c "\\copy $1 FROM '$DATA_DIR/$2' WITH (FORMAT csv, HEADER true)"
}

copy_csv seed.customers            olist_customers_dataset.csv
copy_csv seed.orders               olist_orders_dataset.csv
copy_csv seed.order_items          olist_order_items_dataset.csv
copy_csv seed.order_payments       olist_order_payments_dataset.csv
copy_csv seed.order_reviews        olist_order_reviews_dataset.csv
copy_csv seed.products             olist_products_dataset.csv
copy_csv seed.sellers              olist_sellers_dataset.csv
copy_csv seed.category_translation product_category_name_translation.csv

echo ">> seed.geolocation (aggregating 1M samples to one point per zip prefix)"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q <<'SQL'
DROP TABLE IF EXISTS seed._geo_stage;
CREATE UNLOGGED TABLE seed._geo_stage (
    geolocation_zip_code_prefix text,
    geolocation_lat             text,
    geolocation_lng             text,
    geolocation_city            text,
    geolocation_state           text
);
SQL
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q \
  -c "\\copy seed._geo_stage FROM '$DATA_DIR/olist_geolocation_dataset.csv' WITH (FORMAT csv, HEADER true)"

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q <<'SQL'
INSERT INTO seed.geolocation (zip_code_prefix, lat, lng, city, state, sample_count)
SELECT
    lpad(btrim(g.geolocation_zip_code_prefix), 5, '0'),
    -- median, not mean: a handful of samples per prefix are wildly off and the
    -- mean drags the state centroid into the ocean
    -- percentile_cont returns double precision, and round(double precision, int)
    -- does not exist in Postgres -- only round(numeric, int). Cast, or the load
    -- dies here with "function round(double precision, integer) does not exist".
    round((percentile_cont(0.5) WITHIN GROUP (ORDER BY ops.safe_numeric(g.geolocation_lat)))::numeric, 6),
    round((percentile_cont(0.5) WITHIN GROUP (ORDER BY ops.safe_numeric(g.geolocation_lng)))::numeric, 6),
    mode() WITHIN GROUP (ORDER BY g.geolocation_city),
    mode() WITHIN GROUP (ORDER BY upper(btrim(g.geolocation_state))),
    count(*)
FROM seed._geo_stage g
WHERE ops.safe_numeric(g.geolocation_lat) IS NOT NULL
  AND ops.safe_numeric(g.geolocation_lng) IS NOT NULL
GROUP BY lpad(btrim(g.geolocation_zip_code_prefix), 5, '0');

DROP TABLE seed._geo_stage;
VACUUM ANALYZE seed.geolocation;
SQL

echo
psql "$DATABASE_URL" -q -c "
SELECT 'customers' t, count(*) FROM seed.customers
UNION ALL SELECT 'orders',        count(*) FROM seed.orders
UNION ALL SELECT 'order_items',   count(*) FROM seed.order_items
UNION ALL SELECT 'payments',      count(*) FROM seed.order_payments
UNION ALL SELECT 'reviews',       count(*) FROM seed.order_reviews
UNION ALL SELECT 'products',      count(*) FROM seed.products
UNION ALL SELECT 'sellers',       count(*) FROM seed.sellers
UNION ALL SELECT 'geolocation',   count(*) FROM seed.geolocation
UNION ALL SELECT 'translation',   count(*) FROM seed.category_translation;"

echo
echo "Seed loaded. Next: turn on the n8n workflow, or run scripts/03_drip.sh to"
echo "fast-forward the whole feed locally."
