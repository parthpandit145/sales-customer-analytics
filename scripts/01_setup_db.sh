#!/usr/bin/env bash
# Creates schemas, tables and functions. Safe to re-run: every object is
# CREATE OR REPLACE or DROP-then-CREATE.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/_common.sh
: "${DATABASE_URL:?set DATABASE_URL in scripts/.env}"

for f in sql/00_schemas.sql \
         sql/01_tables_seed_raw_ops.sql \
         sql/02_ingest_functions.sql \
         sql/03_staging.sql \
         sql/04_dim_date.sql \
         sql/05_dimensions.sql \
         sql/06_facts.sql \
         sql/07_analytics.sql \
         sql/08_post_batch.sql \
         sql/09_data_quality.sql \
         sql/11_rls_mapping.sql \
         sql/12_superset_views.sql
do
  echo ">> $f"
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q -f "$f"
done

echo
echo "Schema ready. Next: scripts/02_load_seed.sh"
