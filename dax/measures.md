# DAX measures

Everything here is written for the **Power BI web editor**. Nothing needs Desktop.

Where to put them: create every measure on **`fact_orders`**. The web modeling
view has no "enter data" button, so you cannot make a dedicated blank measures
table there. Parking them on the order fact keeps them in one place and the
folder structure below does the organising instead. Set each measure's **Display
folder** (Properties pane) to the heading it sits under.

Model assumptions: these are the objects imported from the `mart` schema, and
they arrive already named the way every measure below refers to them:

`fact_sales`, `fact_orders`, `dim_customer`, `dim_date`, `dim_product`,
`dim_geo`, `dim_seller`, `dim_payment_type`, `vw_rfm`, `vw_cohort`,
`vw_customer_ltv`, `vw_category_pareto`, `vw_pipeline_health`.

Currency is Brazilian reais. Format the money measures as `R$ #,##0` and set
**Data category → Uncategorized** so Power BI does not try to geocode them.

---

## 01 · Core

`is_valid_sale` excludes `canceled` and `unavailable` orders. It is baked into
the base measures rather than left to a page filter, so a measure dropped onto a
new page can never quietly include cancelled revenue.

```dax
Total Revenue =
CALCULATE (
    SUM ( fact_sales[item_total] ),
    fact_sales[is_valid_sale] = TRUE ()
)
```

```dax
Product Revenue =
CALCULATE ( SUM ( fact_sales[price] ), fact_sales[is_valid_sale] = TRUE () )
```

```dax
Freight Cost =
CALCULATE ( SUM ( fact_sales[freight_value] ), fact_sales[is_valid_sale] = TRUE () )
```

```dax
Total Orders =
CALCULATE (
    DISTINCTCOUNT ( fact_orders[order_id] ),
    fact_orders[is_valid_sale] = TRUE ()
)
```

```dax
Total Items =
CALCULATE ( COUNTROWS ( fact_sales ), fact_sales[is_valid_sale] = TRUE () )
```

```dax
Total Customers =
CALCULATE (
    DISTINCTCOUNT ( fact_orders[customer_unique_id] ),
    fact_orders[is_valid_sale] = TRUE ()
)
```

```dax
Avg Order Value = DIVIDE ( [Total Revenue], [Total Orders] )
```

```dax
Avg Items per Order = DIVIDE ( [Total Items], [Total Orders] )
```

```dax
Revenue per Customer = DIVIDE ( [Total Revenue], [Total Customers] )
```

```dax
Cancellation Rate =
VAR Cancelled =
    CALCULATE ( DISTINCTCOUNT ( fact_orders[order_id] ), fact_orders[is_cancelled] = TRUE () )
VAR AllOrders = CALCULATE ( DISTINCTCOUNT ( fact_orders[order_id] ), REMOVEFILTERS ( fact_orders[is_valid_sale] ) )
RETURN
    DIVIDE ( Cancelled, AllOrders )
```

---

## 02 · Time intelligence

Mark `dim_date` as a date table on `dim_date[date]` first (Table tools → Mark as
date table). None of these work until you do.

```dax
Revenue LY =
CALCULATE ( [Total Revenue], SAMEPERIODLASTYEAR ( dim_date[date] ) )
```

```dax
Revenue YoY % =
VAR Current = [Total Revenue]
VAR Prior = [Revenue LY]
RETURN
    IF ( NOT ISBLANK ( Prior ) && Prior <> 0, DIVIDE ( Current - Prior, Prior ) )
```

The `IF` matters. Olist starts in September 2016, so every month of 2016 and the
first eight months of 2017 have no true prior-year comparison. Without the guard
Power BI renders those as +∞% growth and the trend line becomes a spike.

```dax
Revenue PM =
CALCULATE ( [Total Revenue], DATEADD ( dim_date[date], -1, MONTH ) )
```

```dax
Revenue MoM % =
VAR Prior = [Revenue PM]
RETURN
    IF ( NOT ISBLANK ( Prior ) && Prior <> 0, DIVIDE ( [Total Revenue] - Prior, Prior ) )
```

```dax
Revenue MTD = TOTALMTD ( [Total Revenue], dim_date[date] )
```

```dax
Revenue YTD = TOTALYTD ( [Total Revenue], dim_date[date] )
```

```dax
Revenue QTD = TOTALQTD ( [Total Revenue], dim_date[date] )
```

```dax
Revenue Running Total =
CALCULATE (
    [Total Revenue],
    FILTER (
        ALLSELECTED ( dim_date[date] ),
        dim_date[date] <= MAX ( dim_date[date] )
    )
)
```

`ALLSELECTED` rather than `ALL`: the running total should restart inside
whatever the slicers currently allow, not run from the beginning of the calendar
regardless of what the user filtered.

```dax
Revenue 3M Moving Avg =
VAR Window =
    DATESINPERIOD ( dim_date[date], MAX ( dim_date[date] ), -3, MONTH )
RETURN
    CALCULATE (
        DIVIDE ( [Total Revenue], DISTINCTCOUNT ( dim_date[month_start] ) ),
        Window
    )
```

Total revenue over the trailing three months divided by the number of distinct
months actually present in that window, so the first two months of the series
average over 1 and 2 months instead of returning a third of the true value.

---

## 03 · Pareto / concentration

```dax
% of Total Revenue =
DIVIDE (
    [Total Revenue],
    CALCULATE ( [Total Revenue], ALLSELECTED ( dim_product[category] ) )
)
```

```dax
Cumulative Revenue % =
VAR CurrentRevenue = [Total Revenue]
VAR Categories = ALLSELECTED ( dim_product[category] )
VAR RunningTotal =
    SUMX (
        FILTER ( Categories, CALCULATE ( [Total Revenue] ) >= CurrentRevenue ),
        CALCULATE ( [Total Revenue] )
    )
RETURN
    DIVIDE ( RunningTotal, CALCULATE ( [Total Revenue], Categories ) )
```

Put `Cumulative Revenue %` on the line axis of a combo chart with categories
sorted by `Total Revenue` descending, add a constant line at 80%, and the 80/20
reads straight off the chart.

```dax
Top 20% Customer Revenue Share =
VAR TopRevenue =
    CALCULATE (
        SUM ( vw_customer_ltv[lifetime_value] ),
        vw_customer_ltv[customer_percentile] <= 20
    )
VAR AllRevenue =
    CALCULATE ( SUM ( vw_customer_ltv[lifetime_value] ), REMOVEFILTERS ( vw_customer_ltv ) )
RETURN
    DIVIDE ( TopRevenue, AllRevenue )
```

```dax
Categories to 80% of Revenue =
CALCULATE (
    DISTINCTCOUNT ( vw_category_pareto[category] ),
    vw_category_pareto[is_vital_few] = TRUE ()
)
```

---

## 04 · Customer behaviour

```dax
New Customers =
CALCULATE (
    DISTINCTCOUNT ( fact_orders[customer_unique_id] ),
    fact_orders[is_first_order] = TRUE (),
    fact_orders[is_valid_sale] = TRUE ()
)
```

```dax
Returning Customers = [Total Customers] - [New Customers]
```

```dax
New Customer Revenue =
CALCULATE (
    [Total Revenue],
    TREATAS (
        CALCULATETABLE ( VALUES ( fact_orders[order_id] ), fact_orders[is_first_order] = TRUE () ),
        fact_sales[order_id]
    )
)
```

```dax
Returning Customer Revenue = [Total Revenue] - [New Customer Revenue]
```

```dax
Returning Revenue % = DIVIDE ( [Returning Customer Revenue], [Total Revenue] )
```

```dax
Repeat Customer % =
VAR Repeaters =
    CALCULATE (
        DISTINCTCOUNT ( dim_customer[customer_unique_id] ),
        dim_customer[is_repeat_customer] = TRUE ()
    )
VAR PurchasingCustomers =
    CALCULATE (
        DISTINCTCOUNT ( dim_customer[customer_unique_id] ),
        dim_customer[lifetime_orders] >= 1
    )
RETURN
    DIVIDE ( Repeaters, PurchasingCustomers )
```

The denominator is customers with at least one *valid* order, not every row of
`dim_customer`. The dimension deliberately keeps customers whose only order was
cancelled (dropping them would orphan their fact rows), but they never bought
anything, so counting them in the base would understate the repeat rate.

This is the headline number of the whole project and the one that goes wrong
most often. It is computed off `customer_unique_id`. If you ever see it come out
at exactly 0.00%, the model has been wired to `customer_id`, which Olist
re-issues on every order, making every customer look brand new forever.

```dax
Avg Customer LTV = AVERAGE ( vw_customer_ltv[lifetime_value] )
```

```dax
Median Customer LTV = MEDIAN ( vw_customer_ltv[lifetime_value] )
```

Show both. The mean sits well above the median here and quoting only the mean
overstates what a typical customer is worth.

```dax
Customers in Segment = DISTINCTCOUNT ( vw_rfm[customer_unique_id] )
```

```dax
Segment Revenue = SUM ( vw_rfm[monetary] )
```

```dax
Segment Revenue % =
DIVIDE (
    SUM ( vw_rfm[monetary] ),
    CALCULATE ( SUM ( vw_rfm[monetary] ), REMOVEFILTERS ( vw_rfm ) )
)
```

```dax
Avg Days Between Orders =
AVERAGEX (
    FILTER ( vw_customer_ltv, vw_customer_ltv[total_orders] > 1 ),
    DIVIDE ( vw_customer_ltv[lifespan_days], vw_customer_ltv[total_orders] - 1 )
)
```

---

## 05 · Cohort retention

```dax
Retention % =
DIVIDE (
    SUM ( vw_cohort[active_customers] ),
    SUMX ( VALUES ( vw_cohort[cohort_month] ), CALCULATE ( MAX ( vw_cohort[cohort_size] ) ) )
)
```

The denominator is deliberately not `SUM(cohort_size)`. Cohort size repeats on
every month row of a cohort, so summing it would multiply the denominator by the
number of months and crush the totals row to near zero. `SUMX` over distinct
cohorts adds each cohort's size exactly once.

```dax
Cohort Customers = SUMX ( VALUES ( vw_cohort[cohort_month] ), CALCULATE ( MAX ( vw_cohort[cohort_size] ) ) )
```

```dax
M1 Retention % =
CALCULATE ( [Retention %], vw_cohort[month_index] = 1 )
```

```dax
M3 Retention % = CALCULATE ( [Retention %], vw_cohort[month_index] = 3 )
```

```dax
M6 Retention % = CALCULATE ( [Retention %], vw_cohort[month_index] = 6 )
```

```dax
Revenue per Cohort Customer =
DIVIDE ( SUM ( vw_cohort[cohort_revenue] ), [Cohort Customers] )
```

---

## 06 · Experience and fulfilment

All of these live on `fact_orders`, never `fact_sales`, because averaging a review
score at item grain weights every order by how many items it contained.

```dax
Avg Review Score =
CALCULATE ( AVERAGE ( fact_orders[review_score] ), fact_orders[is_valid_sale] = TRUE () )
```

```dax
Reviewed Orders =
CALCULATE (
    DISTINCTCOUNT ( fact_orders[order_id] ),
    NOT ISBLANK ( fact_orders[review_score] ),
    fact_orders[is_valid_sale] = TRUE ()
)
```

```dax
Detractor % =
VAR Detractors =
    CALCULATE ( DISTINCTCOUNT ( fact_orders[order_id] ), fact_orders[review_band] = "Detractor (1-2)" )
RETURN
    DIVIDE ( Detractors, [Reviewed Orders] )
```

```dax
Promoter % =
VAR Promoters =
    CALCULATE ( DISTINCTCOUNT ( fact_orders[order_id] ), fact_orders[review_band] = "Promoter (4-5)" )
RETURN
    DIVIDE ( Promoters, [Reviewed Orders] )
```

```dax
Revenue at Risk (Detractors) =
CALCULATE (
    SUM ( fact_orders[order_total] ),
    fact_orders[review_band] = "Detractor (1-2)",
    fact_orders[is_valid_sale] = TRUE ()
)
```

```dax
Avg Delivery Days = AVERAGE ( fact_orders[delivery_days] )
```

```dax
Avg Promised Days = AVERAGE ( fact_orders[promised_days] )
```

```dax
Late Delivery % =
VAR Late = CALCULATE ( COUNTROWS ( fact_orders ), fact_orders[is_late] = TRUE () )
VAR Delivered = CALCULATE ( COUNTROWS ( fact_orders ), fact_orders[is_delivered] = TRUE () )
RETURN
    DIVIDE ( Late, Delivered )
```

```dax
Avg Days vs Promise = AVERAGE ( fact_orders[days_vs_promise] )
```

Negative is good here: it means delivery beat the promised date. Format with
one decimal and label the axis "days early / late" so the sign reads correctly.

```dax
Freight % of Product Revenue = DIVIDE ( [Freight Cost], [Product Revenue] )
```

```dax
Avg Freight per Order =
DIVIDE (
    CALCULATE ( SUM ( fact_orders[order_freight] ), fact_orders[is_valid_sale] = TRUE () ),
    [Total Orders]
)
```

---

## 07 · Pipeline health

These back the small "is this data trustworthy" strip on the executive page.
Sourced from `vw_pipeline_health`, which reads `ops.load_batch` directly.

```dax
Data As Of = MAX ( fact_orders[purchase_date] )
```

```dax
Last Batch Loaded = MAX ( vw_pipeline_health[finished_at] )
```

```dax
Rows Rejected (Last Batch) =
VAR LatestBatch = MAX ( vw_pipeline_health[batch_id] )
RETURN
    CALCULATE (
        SUM ( vw_pipeline_health[rows_rejected] ),
        vw_pipeline_health[batch_id] = LatestBatch
    )
```

```dax
Pipeline Reject Rate =
DIVIDE (
    SUM ( vw_pipeline_health[rows_rejected] ),
    SUM ( vw_pipeline_health[rows_loaded] ) + SUM ( vw_pipeline_health[rows_rejected] )
)
```

```dax
Failed Batches =
CALCULATE ( COUNTROWS ( vw_pipeline_health ), vw_pipeline_health[status] = "failed" )
```
