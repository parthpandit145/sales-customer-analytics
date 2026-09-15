#!/usr/bin/env bash
# Gets the Olist Brazilian E-Commerce dataset into ./data
#
# Two ways in. Manual is fine and needs no API token -- you only do this once.
#
#   MANUAL (recommended):
#     1. https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce
#     2. Sign in, click Download (~45 MB zip)
#     3. Run this script -- it finds the zip in ~/Downloads and unpacks it
#
#   CLI (if you already have the Kaggle CLI set up):
#     pip install kaggle, token at ~/.kaggle/kaggle.json, then run this script
set -euo pipefail
cd "$(dirname "$0")/.."

DATA_DIR="${DATA_DIR:-./data}"
mkdir -p "$DATA_DIR"

EXPECTED=(
  olist_customers_dataset.csv olist_orders_dataset.csv olist_order_items_dataset.csv
  olist_order_payments_dataset.csv olist_order_reviews_dataset.csv
  olist_products_dataset.csv olist_sellers_dataset.csv
  olist_geolocation_dataset.csv product_category_name_translation.csv
)

have_all () {
  for f in "${EXPECTED[@]}"; do [ -f "$DATA_DIR/$f" ] || return 1; done
  return 0
}

if have_all; then
  echo "All nine CSVs already present in $DATA_DIR -- nothing to do."
  ls -1 "$DATA_DIR"/*.csv
  exit 0
fi

# 1. An already-extracted folder in Downloads (Safari unzips automatically,
#    and Kaggle's zip extracts to a folder called "archive")
for d in ~/Downloads/archive ~/Downloads/brazilian-ecommerce ~/Downloads; do
  if [ -f "$d/olist_orders_dataset.csv" ]; then
    echo ">> copying CSVs from $d"
    cp "$d"/olist_*.csv "$d"/product_category_name_translation.csv "$DATA_DIR"/ 2>/dev/null || true
    break
  fi
done

# 2. Or a zip still sitting in Downloads
if ! have_all; then
  ZIP=$(ls -t ~/Downloads/*brazilian-ecommerce*.zip ~/Downloads/archive*.zip 2>/dev/null | head -1 || true)
  if [ -n "$ZIP" ]; then
    echo ">> unpacking $ZIP"
    unzip -o -q "$ZIP" -d "$DATA_DIR"
  fi
fi

# 3. Fall back to the Kaggle CLI
if ! have_all && command -v kaggle >/dev/null 2>&1; then
  echo ">> fetching via kaggle CLI"
  kaggle datasets download -d olistbr/brazilian-ecommerce -p "$DATA_DIR" --unzip
fi

if ! have_all; then
  echo
  echo "Could not find the dataset. Do this once, by hand:" >&2
  echo "  1. open https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce" >&2
  echo "  2. sign in and click Download" >&2
  echo "  3. re-run this script (it will pick the zip up from ~/Downloads)" >&2
  echo >&2
  echo "Missing files:" >&2
  for f in "${EXPECTED[@]}"; do [ -f "$DATA_DIR/$f" ] || echo "  - $f" >&2; done
  exit 1
fi

echo
echo "Ready:"
ls -1 "$DATA_DIR"/*.csv
