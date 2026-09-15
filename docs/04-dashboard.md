# 4 · Dashboard specification

Three visible pages plus one hidden drill-through target. Everything below is
buildable in the Service's web report editor.

**House rules for all pages**

- Canvas 16:9, one shared slicer strip across the top: `dim_date[date]` (between
  slicer), `dim_geo[region]`, `dim_geo[state_name]`, `dim_product[category_group]`.
- Sync those slicers across all three pages (View → Sync slicers), but **do not**
  sync visibility so each page shows the strip.
- Currency `R$ #,##0`. Percentages one decimal.
- One accent colour for revenue, one for customers, grey for context. Resist
  giving every card its own colour.
- Bottom-right of every page: a small `Data As Of` text card. A dashboard with
  no visible data date is a dashboard nobody can act on.

---

## Page 1 · Executive Overview

**KPI row**, five cards:

| Card | Measure | Add |
|---|---|---|
| Revenue | `Total Revenue` | `Revenue YoY %` as the callout subtitle |
| Orders | `Total Orders` | |
| Avg Order Value | `Avg Order Value` | |
| Customers | `Total Customers` | |
| Repeat Customer % | `Repeat Customer %` | conditional format red under 5% |

That last card is the one that should make a viewer stop. Leave it red.

**Revenue trend**: line and stacked column chart.
X `dim_date[year_month_label]`, column `Total Revenue`, line `Revenue 3M Moving Avg`.
The raw monthly line is spiky; the moving average is what shows the trend. Show both.

**Revenue by state**: filled map (or shape map).
Location `dim_geo[map_location]`, colour saturation `Total Revenue`,
tooltips `Total Orders`, `Avg Order Value`, `Avg Delivery Days`, `Avg Review Score`.

Use `map_location` (`"Sao Paulo, Brazil"`) rather than the two-letter code, because
Bing resolves the disambiguated string reliably and the codes not at all.

**Top categories**: bar chart, top 10 by `Total Revenue`,
Y `dim_product[category]`, X `Total Revenue`, data labels on.
Apply a Top N filter (`Top 10 by Total Revenue`), not a manual selection.

**Pipeline health strip**: three small cards along the bottom:
`Last Batch Loaded`, `Pipeline Reject Rate`, `Rows Rejected (Last Batch)`.

Small, grey, unglamorous, and the thing that separates a data project from a
chart gallery. It says the numbers above came from a pipeline that is watched.

---

## Page 2 · Customer Analytics

**RFM segments**: bar chart.
Y `vw_rfm[rfm_segment]` (sorted by `segment_rank`), X `Customers in Segment`,
second visual next to it with X `Segment Revenue %`.

Two charts side by side rather than one dual-axis. The story is the gap between
them: a segment that is a sliver of the customer bar and a slab of the revenue
bar is where the money is.

Add a table underneath: `rfm_segment`, `Customers in Segment`, `Segment Revenue`,
`Segment Revenue %`, average `recency_days`, and `recommended_action`. That last
column is written into `mart.vw_rfm`. It turns a segmentation into a to-do list.

**Cohort retention matrix**: matrix visual.
Rows `vw_cohort[cohort_month_label]`, columns `vw_cohort[month_index_label]`,
values `Retention %`. Conditional-format the values with a colour scale, white
low → accent high. Turn row/column subtotals **off**, since retention totals are
meaningless and actively misleading.

**Retention KPIs**: three cards: `M1 Retention %`, `M3 Retention %`,
`M6 Retention %`.

**LTV distribution**: column chart.
X `vw_customer_ltv[ltv_band]`, Y `Total Customers`, line `Avg Customer LTV`.
Add cards for `Avg Customer LTV` and `Median Customer LTV` side by side. The
distance between them is the point.

**New vs returning revenue**: stacked area over `dim_date[year_month_label]`,
`New Customer Revenue` and `Returning Customer Revenue`, plus a card for
`Returning Revenue %`.

**Concentration**: card `Top 20% Customer Revenue Share`, with a line chart
behind it: X `vw_customer_ltv[customer_percentile]` binned, Y
`cumulative_revenue_pct`. That is the Lorenz curve for your customer base.

---

## Page 3 · Product & Profitability

**Pareto**: line and stacked column chart.
X `dim_product[category]` sorted by `Total Revenue` descending,
column `Total Revenue`, line `Cumulative Revenue %` on the secondary axis,
constant line at 80% on the secondary axis.
Card alongside: `Categories to 80% of Revenue`.

**Revenue vs freight**: scatter chart.
X `Product Revenue`, Y `Freight % of Product Revenue`, size `Total Items`,
legend `dim_product[category_group]`, details `dim_product[category]`.

The top-right quadrant (high revenue *and* high freight ratio) is the
margin-erosion story. Add an average line on each axis so the quadrants read
without the viewer doing arithmetic.

**Review score vs revenue**: column chart.
X `fact_orders[review_band]`, Y `Total Revenue`, line `Avg Order Value`.
Second visual: line chart, X delivery-speed band, Y `Avg Review Score`.

Build the speed band as a calculated column on `fact_orders` if you want it in
the model, or just chart `Avg Days vs Promise` against `Avg Review Score` by
category and let the correlation show itself.

**Delivery performance**: cards: `Avg Delivery Days`, `Late Delivery %`,
`Avg Days vs Promise`, `Detractor %`, `Revenue at Risk (Detractors)`.

**Category table** with drill-through enabled: `category`, `Total Revenue`,
`% of Total Revenue`, `Freight % of Product Revenue`, `Avg Review Score`,
`Total Items`.

---

## Page 4 · Product Detail (hidden, drill-through target)

Set **Drill through → Add drill-through fields → `dim_product[category]`**, and
hide the page (right-click the tab → Hide page).

On it: product-level table (`product_id`, `Total Revenue`, `Total Items`,
`Avg Review Score`, `weight_band`, `photo_band`), a `Total Revenue` by
`weight_band` column chart, and a card row repeating the category's headline
numbers. Keep the auto-generated back button.

---

## Interactions to set up

**Bookmarks** on Page 1: build two views of the trend visual (revenue by month
vs orders by month) and wire a bookmark navigator so the viewer can flip between
them without a second chart taking up space.

**Edit interactions**: the pipeline health cards on Page 1 should *not* be
filtered by the date slicer. Select the slicer → Format → Edit interactions →
set those three cards to **None**. Otherwise picking a 2017 date range makes the
"last batch loaded" card go blank, which looks like a broken pipeline.

**Tooltips**: make a small hidden tooltip page with `Total Orders`,
`Avg Order Value`, `Avg Review Score`, `Late Delivery %` and set it as the
tooltip for the map and the category bar chart.

---

## What to check before you call it done

- Every visual still renders when the date slicer is set to a single month.
- No visual shows `(Blank)` as a category label. That means a failed join.
- The revenue on Page 1 equals the revenue on Page 3. If it does not, one page
  is using `fact_sales` and the other `fact_orders` without the `is_valid_sale`
  filter.
- `Repeat Customer %` is not 0.00%. If it is, the model is keyed on
  `customer_id` instead of `customer_unique_id`.
- Test the report as a restricted RLS role and confirm the customer visuals are
  filtered too, not just the map.
