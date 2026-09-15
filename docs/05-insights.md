# 5 · Insight summary

All figures below come from `sql/10_insight_queries.sql` run against the full
loaded dataset on 2026-08-25. Re-run it any time to refresh them:

```bash
psql "$DATABASE_URL" -f sql/10_insight_queries.sql
```

> The numbers are verified. The **So what** lines are deliberately left for you
> to write. They are the part an interviewer is actually listening for, and
> they need to be in your own words. Delete this note when you have.

---

## Headline

Between **2016-09-04** and **2018-09-03**, Olist processed **98,207 valid orders**
(112,101 items) worth **R$15.74M** from **94,990 customers**, at an average order
value of **R$160.23**.

---

## 1. Revenue is concentrated, but less brutally than the 80/20 rule suggests

| Top share of customers | Share of revenue |
|---|---|
| 1% | 10.3% |
| 5% | 26.8% |
| 10% | 38.3% |
| 20% | **53.6%** |
| 50% | 80.8% |

The real Pareto here is closer to 50/80 than 20/80. Worth saying plainly rather
than forcing the dataset into the cliché: because almost everyone buys exactly
once, revenue concentration is driven by *basket size*, not purchase frequency.

**So what:** _(your call: what does a 20% → 53.6% curve mean for where marketing
spend should go?)_

---

## 2. Retention is the constraint, and it is severe

Only **3.04%** of customers ever place a second order, 2,888 of 94,990. Average
orders per customer is **1.034**. Mean LTV is **R$165.65**; median is **R$107.90**.

Cohort retention:

| Month | Cohorts old enough | Base | Still active | Retention |
|---|---|---|---|---|
| M1 | 21 | 94,698 | 429 | **0.45%** |
| M3 | 17 | 76,552 | 198 | 0.26% |
| M6 | 15 | 56,627 | 130 | 0.23% |
| M12 | 8 | 21,933 | 39 | 0.18% |

Repeat customers generate **R$890K, or 5.66% of revenue**.

**Say this out loud in an interview before anyone asks:** a sub-1% M1 retention
is not a broken funnel, it is what a marketplace looks like. Olist customers buy
a specific item from a specific seller and leave. The analytical consequence is
that acquisition cost has to be recovered on the *first* order, which changes
which levers matter. Nobody should be building a loyalty programme on this data.

**So what:** _(if repeat rate went 3.04% → 5%, what is that worth at R$160 AOV?
Compute it.)_

---

## 3. Seventeen of 74 categories carry 80% of revenue

| # | Category | Revenue | % of total | Cumulative |
|---|---|---|---|---|
| 1 | Health Beauty | R$1.44M | 9.14% | 9.1% |
| 2 | Watches Gifts | R$1.30M | 8.25% | 17.4% |
| 3 | Bed Bath Table | R$1.24M | 7.88% | 25.3% |
| 4 | Sports Leisure | R$1.15M | 7.29% | 32.6% |
| 5 | Computers Accessories | R$1.05M | 6.68% | 39.2% |

**17 of 74 categories (23%)** reach 80% of revenue, a textbook Pareto on the
product side, in contrast to the flatter curve on the customer side.

---

## 4. Freight erodes margin unevenly, and it tracks bulk

Freight is **16.61%** of product revenue overall, or **R$2.24M**. By category it
ranges from 8% to 25%:

| Category | Revenue | Freight as % of revenue |
|---|---|---|
| Office Furniture | R$342K | **25.04%** |
| Furniture Decor | R$900K | **23.67%** |
| Housewares | R$772K | 23.17% |
| Telephony | R$393K | 22.01% |
| Bed Bath Table | R$1.24M | 19.73% |
| Watches Gifts | R$1.30M | **8.35%** |

Watches Gifts earns nearly four times the revenue of Office Furniture at a third
of the freight burden. The pattern is bulk: heavy, low-density furniture costs
far more to move per real of revenue than small high-value goods.

**So what:** _(which of these justify a shipping-price change, a weight
threshold, or regional fulfilment? Name them.)_

---

## 5. Late delivery is measurably, expensively destructive

| | Orders | Avg review | Detractors | AOV |
|---|---|---|---|---|
| On time | 88,163 | **4.29** | 9.2% | R$158.54 |
| Late | 7,661 | **2.57** | **54.1%** | R$171.29 |

Being late costs **1.7 stars** and multiplies the detractor rate nearly sixfold.
It gets worse monotonically with elapsed time:

| Delivery speed | Orders | Avg review | AOV |
|---|---|---|---|
| 0-3 days | 6,926 | 4.46 | R$124.41 |
| 4-7 days | 23,624 | 4.40 | R$143.74 |
| 8-14 days | 37,775 | 4.30 | R$161.54 |
| 15-30 days | 23,319 | 3.94 | R$175.93 |
| 30+ days | 4,188 | **2.21** | R$198.02 |

Note the second pattern, which is the more interesting finding: **AOV rises as
delivery gets slower**. Bigger baskets are bulkier, bulkier ships slower, slower
gets punished in reviews. The customers having the worst experience are the ones
spending the most. **R$1.35M of revenue sat in the 7,826 late orders.**

**So what:** _(late orders are the highest-value ones. What does that imply about
where fulfilment investment should go?)_

---

## 6. Geography is lopsided, and distance shows up as unhappiness

| State | Revenue share | Avg delivery | Avg review |
|---|---|---|---|
| São Paulo | **37.36%** | **8.7 days** | 4.21 |
| Rio de Janeiro | 13.45% | 15.2 days | 3.90 |
| Minas Gerais | 11.71% | 11.9 days | 4.16 |
| Bahia | 3.86% | 19.3 days | 3.88 |
| Ceará | 1.74% | **21.2 days** | 3.88 |

São Paulo alone is over a third of revenue and gets its orders in less than half
the time Ceará does. AOV runs the other way. Ceará averages **R$207.50** against
São Paulo's **R$142.93**, so the least-served states are the highest-value
baskets.

---

## 7. Payment mix

| Method | Orders | Share | AOV | Avg instalments |
|---|---|---|---|---|
| Credit card | 74,116 | 75.5% | R$166.60 | 3.55 |
| Boleto | 19,539 | 19.9% | R$144.66 | 1.00 |
| Voucher | 3,037 | 3.1% | R$114.93 | 1.00 |
| Debit card | 1,514 | 1.5% | R$140.30 | 1.00 |

One in five orders is paid by **boleto**: a printed bank slip paid in cash at a
bank or lottery agent, with no card involved. It carries a 13% lower AOV and
cannot be instalment-financed. Any analysis that treats Brazilian e-commerce as
card-first misses a fifth of the market.

---

## 8. RFM segments

| Segment | Customers | % | Revenue | % of revenue | Avg value |
|---|---|---|---|---|---|
| Loyal Customers | 22,574 | 23.8% | R$6.64M | **42.2%** | R$294 |
| At Risk | 14,930 | 15.7% | R$4.59M | **29.2%** | R$308 |
| Lost | 11,625 | 12.2% | R$843K | 5.4% | R$73 |
| Hibernating | 11,394 | 12.0% | R$831K | 5.3% | R$73 |
| Needs Attention | 11,240 | 11.8% | R$809K | 5.1% | R$72 |
| Promising | 11,067 | 11.7% | R$811K | 5.2% | R$73 |
| New Customers | 11,104 | 11.7% | R$809K | 5.1% | R$73 |
| Champions | 1,009 | 1.1% | R$375K | 2.4% | R$371 |
| Cannot Lose Them | 47 | 0.0% | R$26K | 0.2% | R$561 |

**At Risk holds 29.2% of revenue**, nearly R$4.6M, at an average recency of 399
days. That is the single most actionable line in the table.

Read the caveat honestly: because 97% of customers order once, the frequency
score is near-constant and segmentation is driven almost entirely by recency and
monetary value. "Champions" is small not because few customers are valuable but
because the definition requires repeat purchases this dataset barely contains.
`mart.vw_rfm` bands frequency explicitly rather than using `NTILE(5)` for exactly
this reason.

---

## Recommendations

Write three. Each tied to a number above, in this shape:

1. **Do X.** Because `<metric>` is `<value>`. Expected effect: `<estimate>`.
   Measured by `<which measure on which page>`.

Anyone can produce charts. This section is what says you understood the business.

---

## Method note

The questions an interviewer will ask anyway.

- **Customer identity.** Olist issues a new `customer_id` for every order. All
  customer-level analysis keys on `customer_unique_id`, so 99,441 order-scoped ids
  collapse to 96,096 people. Without this the repeat rate reads as exactly 0%,
  and a data-quality check (`customer_grain_collapsed`) asserts on it every batch.
- **"Today".** Recency is measured against the last purchase date in the data
  (`mart.v_analysis_date`), not the wall clock. Against real time every customer
  would be years dormant and RFM would collapse into one bucket.
- **RFM frequency scoring.** Explicit bands, not `NTILE(5)`. With 97% of
  customers at exactly one order, quintiles would split identical customers
  across buckets on tie-break order alone.
- **Cancelled orders.** `canceled` and `unavailable` are excluded via
  `is_valid_sale`, baked into the base DAX measures rather than applied as a page
  filter. 99,441 orders in the source, 98,207 valid.
- **Payment allocation.** Payments are recorded per order; the item-grain fact
  allocates them proportionally to item value. Vouchers mean payment totals do
  not always tie to item totals, so `payment_gap` is exposed rather than hidden
  and a check monitors it. It currently runs at 3.22% of orders.
- **Completeness.** 100% of source orders reached the warehouse, 0 rejected, and
  `orders_skipped_silently` asserts that nothing the watermark passed is missing
  from both `raw.orders` and `ops.load_errors`.
