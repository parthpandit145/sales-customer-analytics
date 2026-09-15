#!/usr/bin/env bash
# Fast-forwards the drip locally instead of waiting for n8n's schedule.
# Same function n8n calls, same watermark, same reject logging.
#
#   scripts/03_drip.sh            # 200 batches of 500 orders
#   scripts/03_drip.sh 40 2500    # 40 batches of 2500
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/_common.sh
: "${DATABASE_URL:?set DATABASE_URL in scripts/.env}"

RUNS="${1:-200}"
SIZE="${2:-500}"

for i in $(seq 1 "$RUNS"); do
  OUT=$(psql "$DATABASE_URL" -At -v ON_ERROR_STOP=1 \
        -c "SELECT orders_attempted || '|' || rows_loaded || '|' || rows_rejected || '|' || status
              FROM ops.ingest_next_batch($SIZE);")
  IFS='|' read -r ATTEMPTED LOADED REJECTED STATUS <<< "$OUT"
  printf 'batch %-4s orders=%-6s rows=%-7s rejected=%-5s %s\n' "$i" "$ATTEMPTED" "$LOADED" "$REJECTED" "$STATUS"
  [ "$ATTEMPTED" = "0" ] && { echo "source drained"; break; }
done

echo
echo ">> refreshing planner statistics"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "SELECT * FROM ops.post_batch_maintenance();"

echo
echo ">> data quality"
psql "$DATABASE_URL" -c "SELECT check_name, severity, status, observed, threshold FROM ops.run_dq_checks();"
