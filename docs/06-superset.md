# 6 · Apache Superset (Preset Cloud) → Neon

Superset connects straight to Postgres with a connection string. No dataflow, no
lakehouse, no gateway, no capacity licence.

## What changes coming from Power BI

**There is no semantic model.** A Superset chart is built on exactly one dataset,
and there are no relationships between datasets. That is why `sql/12_superset_views.sql`
exists — it flattens the star schema into three wide views. The dimensional model
in `sql/04`–`sql/07` is still the source of truth; these are a presentation layer
on top of it.

**Metrics replace DAX.** A Superset metric is a SQL aggregate expression saved on
a dataset. The time-intelligence measures — YoY, moving average, running total —
are not written at all; they are options in Superset's **Advanced Analytics**
panel.

**Superset queries live.** Power BI imports a snapshot twice a day; Superset hits
Postgres on every chart render and every filter change. That inverts the
materialisation decision — see the header of `sql/08_post_batch.sql`.

---

## 6.1 · Create the read-only role

Do this before touching Preset:

```bash
scripts/04_superset_role.sh
```

It creates `superset_ro`, grants it `SELECT` on the `mart` schema and nothing
else, verifies it **cannot** read `raw.customers` and **cannot** write, and
writes a ready-made connection URI to `scripts/.superset_uri` (gitignored,
mode 600).

This matters more than it looks. Superset ships **SQL Lab** — anyone who can log
into the dashboard can run arbitrary SQL with whatever credentials the connection
holds. With `neondb_owner` that includes `DROP TABLE`. `superset_ro` can read the
mart views and nothing else; it cannot reach the raw customer records in `seed`
or `raw`, cannot touch the pipeline telemetry, and cannot write anywhere.

Rotate the password any time by re-running the script.

---

## 6.2 · Preset

1. Sign up at **preset.io** — free tier, no card.
2. Create a workspace.
3. **Data → Databases → + Database → PostgreSQL**, and choose the
   **SQLAlchemy URI** option rather than filling the host/port fields.
4. Paste the line from `scripts/.superset_uri`:

   ```
   postgresql+psycopg2://superset_ro:...@ep-xxxx-pooler.REGION.aws.neon.tech:5432/neondb?sslmode=require
   ```

   Open that file to copy it. Don't paste it into a chat window — it contains
   the password.

5. **Advanced → SQL Lab**: leave "Allow DDL and DML" **off**. The role blocks it
   anyway, but defence in depth costs nothing.
6. **Advanced → Performance → Cache timeout**: `3600`. The pipeline refreshes
   every 15 minutes and nobody needs sub-hour freshness on a portfolio dashboard.
   This is what keeps Neon's compute hours down.
7. **Test connection**, then **Connect**.

> First connection may take a second or two — Neon suspends compute when idle and
> wakes on connect.

---

## 6.3 · Datasets

**Data → Datasets → + Dataset**, schema `mart`, one per row:

| Dataset | Grain | Use for |
|---|---|---|
| `bi_sales` | order item | revenue, freight, product, category, seller, geography |
| `bi_orders` | order | AOV, reviews, delivery, new vs returning, payments |
| `bi_customer` | person | RFM, LTV, concentration, cohort membership |
| `vw_cohort` | cohort × month | the retention matrix |
| `vw_category_pareto` | category | the 80/20, cumulative % precomputed in SQL |
| `vw_pipeline_health` | batch | the trust strip |

After creating `bi_sales` and `bi_orders`, **Edit dataset → Settings → Main
Datetime Column → `purchase_date`**. Time-series charts do not appear as options
until a dataset has one.

Two rules that keep the numbers honest, both enforced by how the views are built:

- **Never measure `order_review_score` on `bi_sales`.** It is an order attribute
  carried at item grain for filtering only — averaging it weights every order by
  how many items it contained. The `_order` suffix is the reminder. Use `bi_orders`.
- **`is_valid_sale` excludes cancelled and unavailable orders.** Every revenue
  metric below bakes it in via a `FILTER` clause rather than relying on a chart
  filter, so a metric dropped onto a new chart can never silently include
  cancelled revenue.

---

## 6.4 · Metrics

**Edit dataset → Metrics → + Add item.** Give each a metric key, a readable
label, and the SQL expression.

### On `bi_sales`

| Metric | Expression |
|---|---|
| Total Revenue | `SUM(item_total) FILTER (WHERE is_valid_sale)` |
| Product Revenue | `SUM(price) FILTER (WHERE is_valid_sale)` |
| Freight Cost | `SUM(freight_value) FILTER (WHERE is_valid_sale)` |
| Total Items | `COUNT(*) FILTER (WHERE is_valid_sale)` |
| Total Orders | `COUNT(DISTINCT order_id) FILTER (WHERE is_valid_sale)` |
| Total Customers | `COUNT(DISTINCT customer_unique_id) FILTER (WHERE is_valid_sale)` |
| Avg Order Value | `SUM(item_total) FILTER (WHERE is_valid_sale) / NULLIF(COUNT(DISTINCT order_id) FILTER (WHERE is_valid_sale), 0)` |
| Freight % of Revenue | `SUM(freight_value) FILTER (WHERE is_valid_sale) / NULLIF(SUM(price) FILTER (WHERE is_valid_sale), 0)` |

`FILTER (WHERE ...)` is standard Postgres and far more readable than
`SUM(CASE WHEN ... THEN ... ELSE 0 END)`. Superset passes it through untouched.

### On `bi_orders`

| Metric | Expression |
|---|---|
| Total Revenue | `SUM(order_total) FILTER (WHERE is_valid_sale)` |
| Total Orders | `COUNT(*) FILTER (WHERE is_valid_sale)` |
| Avg Order Value | `AVG(order_total) FILTER (WHERE is_valid_sale)` |
| Avg Review Score | `AVG(review_score) FILTER (WHERE is_valid_sale)` |
| Detractor % | `COUNT(*) FILTER (WHERE review_band = 'Detractor (1-2)')::numeric / NULLIF(COUNT(*) FILTER (WHERE review_score IS NOT NULL), 0)` |
| Promoter % | `COUNT(*) FILTER (WHERE review_band = 'Promoter (4-5)')::numeric / NULLIF(COUNT(*) FILTER (WHERE review_score IS NOT NULL), 0)` |
| Late Delivery % | `COUNT(*) FILTER (WHERE is_late)::numeric / NULLIF(COUNT(*) FILTER (WHERE is_delivered), 0)` |
| Avg Delivery Days | `AVG(delivery_days)` |
| Avg Days vs Promise | `AVG(days_vs_promise)` |
| Cancellation Rate | `COUNT(*) FILTER (WHERE is_cancelled)::numeric / NULLIF(COUNT(*), 0)` |
| New Customer Revenue | `SUM(order_total) FILTER (WHERE is_valid_sale AND is_first_order)` |
| Returning Revenue % | `SUM(order_total) FILTER (WHERE is_valid_sale AND NOT is_first_order) / NULLIF(SUM(order_total) FILTER (WHERE is_valid_sale), 0)` |
| Revenue at Risk | `SUM(order_total) FILTER (WHERE is_valid_sale AND review_band = 'Detractor (1-2)')` |

The `::numeric` casts matter. `COUNT(*)` returns `bigint` and Postgres does
integer division on `bigint / bigint`, so without the cast every percentage
metric silently returns `0`.

### On `bi_customer`

| Metric | Expression |
|---|---|
| Customers | `COUNT(*)` |
| Repeat Customer % | `COUNT(*) FILTER (WHERE is_repeat_customer)::numeric / NULLIF(COUNT(*) FILTER (WHERE lifetime_orders >= 1), 0)` |
| Total LTV | `SUM(lifetime_value)` |
| Avg LTV | `AVG(lifetime_value)` |
| Median LTV | `PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY lifetime_value)` |
| Avg Recency Days | `AVG(recency_days)` |

Show mean and median LTV side by side. The mean sits well above the median here
(R$165.65 against R$107.90) and quoting only the mean overstates what a typical
customer is worth.

The `Repeat Customer %` denominator is customers with at least one *valid* order.
`bi_customer` keeps people whose only order was cancelled — dropping them would
orphan fact rows — but they never bought anything.

### On `vw_cohort`

| Metric | Expression |
|---|---|
| Retention % | `SUM(active_customers)::numeric / NULLIF(SUM(cohort_size), 0)` |
| Cohort Size | `MAX(cohort_size)` |

`(cohort_month, month_index)` is unique, so in a pivot each cell is one row and
this is exact. It also stays correct down a column (all cohorts at month 3),
where it becomes a properly weighted average.

---

## 6.5 · Dashboard

One dashboard, three tabs, mirroring the original three pages.

Add a **filter box** in the left filter bar, applied to all tabs:
`purchase_date` (time range), `customer_region`, `customer_state`,
`product_category_group`.

### Tab 1 · Executive Overview

| Chart | Type | Config |
|---|---|---|
| KPI row | 5 × **Big Number** | Total Revenue, Total Orders, Avg Order Value, Total Customers (all `bi_sales`), Repeat Customer % (`bi_customer`) |
| Revenue trend | **Time-series Line Chart** | `bi_orders`, X `purchase_date` grain Month, metric Total Revenue |
| Revenue by state | **Country Map** or **Bar Chart** | `bi_orders`, dimension `customer_state`, metric Total Revenue |
| Top categories | **Bar Chart** | `bi_sales`, dimension `product_category`, metric Total Revenue, Row limit 10, sort descending |
| Pipeline health | **Table** | `vw_pipeline_health`, latest 10 batches |

On the revenue trend, open **Advanced Analytics**:
- **Rolling window** → Rolling function `mean`, Periods `3` → the 3-month moving average
- **Time comparison** → Time shift `1 year ago`, Calculation `Percentage change` → YoY

That is the whole of the DAX time-intelligence section, replaced by two form
fields. Do add a second copy of the chart rather than stacking both on one — a
rolling mean and a YoY percentage on the same axis is unreadable.

Superset's **Country Map** needs ISO codes and Brazil's regions are supported,
but state-code matching is fiddly; a sorted bar chart of `customer_state` reads
just as well and never silently drops a state. Try the map, keep the bar chart if
it fights you.

### Tab 2 · Customer Analytics

| Chart | Type | Config |
|---|---|---|
| RFM segment sizes | **Bar Chart** | `bi_customer`, dimension `rfm_segment`, metric Customers |
| RFM revenue share | **Bar Chart** | `bi_customer`, dimension `rfm_segment`, metric Total LTV |
| Segment action table | **Table** | `bi_customer`, columns `rfm_segment`, Customers, Total LTV, Avg Recency Days, `recommended_action` |
| Cohort retention | **Pivot Table v2** | `vw_cohort`, rows `cohort_month_label`, columns `month_index_label`, metric Retention % |
| LTV distribution | **Bar Chart** | `bi_customer`, dimension `ltv_band`, metric Customers |
| New vs returning | **Time-series Bar Chart** | `bi_orders`, X `purchase_date` Month, dimension `customer_type`, metric Total Revenue, stacked |
| Concentration | **Line Chart** | `bi_customer`, X `customer_percentile`, metric `MAX(cumulative_revenue_pct)` |

Put the two RFM bar charts side by side. The story is the gap between them — a
segment that is a sliver of the customer bar and a slab of the revenue bar is
where the money is. Here that is **At Risk**: 15.7% of customers, 29.2% of revenue.

On the pivot table, turn **row and column subtotals off**. Retention totals are
meaningless and actively misleading. Turn on conditional formatting for the
colour scale that makes a cohort matrix readable.

Sort `rfm_segment` by `segment_rank`, not alphabetically — add `segment_rank` as
a column and sort on it, or the segments come out in nonsense order.

### Tab 3 · Product & Profitability

| Chart | Type | Config |
|---|---|---|
| Pareto | **Mixed Chart** | `vw_category_pareto`, X `category`, bars `SUM(gross_revenue)`, line `MAX(cumulative_pct_of_revenue)` |
| Revenue vs freight | **Bubble Chart** | `vw_category_pareto`, X `SUM(product_revenue)`, Y `MAX(freight_pct_of_product_revenue)`, size `SUM(items_sold)`, series `category_group` |
| Review vs delivery speed | **Bar Chart** | `bi_orders`, dimension `delivery_speed_band`, metrics Avg Review Score and Avg Order Value |
| Late vs on-time | **Table** | `bi_orders`, dimension `is_late`, metrics Total Orders, Avg Review Score, Detractor %, Avg Order Value |
| Delivery KPIs | 4 × **Big Number** | Avg Delivery Days, Late Delivery %, Detractor %, Revenue at Risk |
| Category detail | **Table** | `bi_sales`, `product_category` with Total Revenue, Freight % of Revenue, Total Items |

The Pareto needs no clever charting because `cumulative_pct_of_revenue` is
already computed in SQL — Superset just plots a column. If the Mixed Chart fights
you over the dual axis, a Table on `vw_category_pareto` with revenue, `% of
total` and `cumulative %` communicates the same thing and sorts properly.

The review-vs-speed chart is the one worth building carefully. It carries the
strongest finding in the dataset: reviews fall from 4.46 to 2.21 as delivery
slows, while AOV *rises* from R$124 to R$198. The customers having the worst
experience are the ones spending the most.

---

## 6.6 · Row-level security

**Settings → Row Level Security → + Rule.**

### Static

| Field | Value |
|---|---|
| Rule type | Regular |
| Datasets | `bi_sales`, `bi_orders`, `bi_customer` |
| Roles | `Southeast` (create under Settings → List Roles) |
| Clause | `customer_region = 'Southeast'` |

The clause is raw SQL appended to the `WHERE` of every query against those
datasets.

### Dynamic

One rule instead of one per region, driven by the mapping table already in the
database (`mart.rls_user_region`):

```sql
customer_region IN (
    SELECT region FROM mart.rls_user_region
    WHERE user_email = '{{ current_username() }}'
)
```

Needs **template processing** enabled on the database (Advanced → SQL Lab →
"Enable Jinja templating"). Adding a regional manager then becomes an `INSERT`,
with no Superset change at all. That table has a `CHECK` constraint on the region
name, because a typo gives someone an empty dashboard that looks identical to a
quiet month.

Apply the rule to **all three** datasets. Securing only `bi_sales` locks down
revenue while leaving the RFM and LTV customer lists wide open — which is exactly
what regional RLS is supposed to protect.

---

## 6.7 · Sharing

**Dashboard → ⋯ → Share → Copy permalink**, and set the dashboard to published.
Preset's free tier requires viewers to have an account, so for a public portfolio
also export a PDF (**⋯ → Download → Export to PDF**) and drop screenshots into
`docs/img/`.

---

## Gotchas

| Symptom | Cause |
|---|---|
| Percentage metric always `0` | integer division — add `::numeric` to the `COUNT(*)` |
| No time-series chart types offered | dataset has no Main Datetime Column set |
| Cohort matrix totals look absurd | pivot subtotals are on — turn them off |
| RFM segments in alphabetical order | sort by `segment_rank`, not the label |
| Columns missing after a SQL change | Edit dataset → **Sync columns from source** |
| First chart of the day is slow | Neon cold start, ~1–2 s, then cached |
| `permission denied for schema raw` | working as intended — `superset_ro` only sees `mart` |
