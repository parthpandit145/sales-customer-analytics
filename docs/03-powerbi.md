# 3 · Power BI in the browser (Fabric trial → Neon)

Everything here is done in a browser. No Desktop, no `.pbix`, no gateway.

## Why this path

Connecting the Power BI **Service** to a PostgreSQL database is the one genuinely
awkward part of a browser-only build, and it is worth knowing exactly why:

- A **free** licence cannot create dataflows at all, so there is no cloud path
  from the Service to Postgres.
- **Dataflow Gen1** (Pro) *can* see PostgreSQL but insists on an on-premises data
  gateway even when the database is public and internet-reachable — Power BI has
  no way to know the host is not behind a corporate firewall.
- **Dataflow Gen2** (Fabric) does not need a gateway for cloud sources. A public
  Neon endpoint with SSL connects directly.

The Fabric trial gives 60 days of F64 capacity for free, which is what makes the
direct connection possible. Read *Surviving the trial expiry* at the bottom
before you start — it changes nothing about the build, but it determines whether
your dashboard is still refreshing in three months.

## 3.1 · Turn on the trial and make a workspace

1. **app.powerbi.com** → account menu → **Start trial** (Fabric, 60 days, F64).
2. **Workspaces → New workspace** → `Sales & Customer Analytics`.
3. Advanced → **License mode: Trial**. If you skip this the workspace sits on
   shared capacity and Dataflow Gen2 will not be available in it.

## 3.2 · Lakehouse

**+ New → Lakehouse** → `olist_lh`.

The dataflow needs somewhere to land the data. A Lakehouse is the least
ceremony, and its SQL analytics endpoint gives you a semantic model for free.

## 3.3 · Dataflow Gen2 against Neon

**+ New → Dataflow Gen2** → name it `df_olist_mart`.

**Get data → PostgreSQL database**, then **New connection**:

| Field | Value |
|---|---|
| Server | `ep-xxxx-pooler.REGION.aws.neon.tech:5432` |
| Database | `neondb` |
| Connection | Create new connection (cloud — leave the gateway blank) |
| Authentication kind | Basic |
| Username / Password | your Neon credentials |
| Use encrypted connection | **checked** — Neon refuses plaintext |
| Privacy level | Organizational |

Select these 14 objects from the `mart` schema:

| Object | Grain | Rows | Notes |
|---|---|---|---|
| `fact_sales` | order item | 112,650 | the big one |
| `fact_orders` | order | 99,441 | |
| `dim_customer` | person | 96,096 | keyed on `customer_unique_id` |
| `vw_rfm` | person | 94,990 | |
| `vw_cohort` | cohort × month | 220 | |
| `vw_customer_ltv` | person | 94,990 | |
| `vw_category_pareto` | category | 74 | reference / cross-check |
| `dim_date` | day | 1,096 | |
| `dim_product` | product | 32,951 | |
| `dim_geo` | state | 27 | RLS dimension |
| `dim_seller` | seller | 3,095 | |
| `dim_payment_type` | payment type | 4 | |
| `vw_pipeline_health` | batch | ~100 | |
| `rls_user_region` | user × region | 8 | RLS mapping |

These are plain views, not materialised copies. That was measured, not assumed:
the slowest of them takes 1.78 s to scan in full, and Power BI reads each one
twice a day. A materialised layer bought no meaningful speed and cost 163 MB of
the 512 MB free tier — see the header of `sql/08_post_batch.sql`.

Import the **views, not the raw tables**. Everything arrives clean, typed and
modelled, so there is nothing left to do in Power Query — which is exactly the
point of having done the work in SQL.

For each query: **Data destination → Lakehouse** `olist_lh`, update method
**Replace**. Then **Publish**.

Set the dataflow's refresh schedule to run **after** an n8n batch, not before —
n8n refreshes the materialised views at the end of every run, and a dataflow
that fires first just reimports the previous batch. It also wakes Neon's compute
so the first query does not hit a cold start.

## 3.4 · Semantic model

Open `olist_lh` → **SQL analytics endpoint** → **New semantic model**. Select
all 14 tables.

The table names arrive exactly as `dax/measures.md` expects them, so there is
nothing to rename.

### Relationships

Open the model → **Model** view → drag to create:

| From (one) | To (many) | Cardinality | Cross-filter |
|---|---|---|---|
| `dim_date[date]` | `fact_orders[purchase_date]` | 1:* | Single |
| `dim_date[date]` | `fact_sales[purchase_date]` | 1:* | Single |
| `dim_customer[customer_unique_id]` | `fact_orders[customer_unique_id]` | 1:* | Single |
| `dim_customer[customer_unique_id]` | `fact_sales[customer_unique_id]` | 1:* | Single |
| `dim_product[product_id]` | `fact_sales[product_id]` | 1:* | Single |
| `dim_seller[seller_id]` | `fact_sales[seller_id]` | 1:* | Single |
| `dim_geo[state_code]` | `fact_orders[customer_state_code]` | 1:* | Single |
| `dim_geo[state_code]` | `fact_sales[customer_state_code]` | 1:* | Single |
| `dim_payment_type[payment_type]` | `fact_orders[payment_type]` | 1:* | Single |
| `dim_payment_type[payment_type]` | `fact_sales[payment_type]` | 1:* | Single |
| `dim_customer[customer_unique_id]` | `vw_rfm[customer_unique_id]` | 1:1 | **Both** |
| `dim_customer[customer_unique_id]` | `vw_customer_ltv[customer_unique_id]` | 1:1 | **Both** |

Leave **unrelated**: `vw_cohort`, `vw_category_pareto`, `vw_pipeline_health`,
`rls_user_region`.

Three decisions in that table are worth being able to defend:

**Why `vw_rfm` is bidirectional.** RFM segment lives on the customer, but every
interesting question is "how much *revenue* comes from Champions?". Revenue is
on the fact. The filter has to travel `vw_rfm → dim_customer → fact_sales`, and
the first hop is uphill, so that relationship must be bidirectional. It is safe
because it is 1:1 and `vw_rfm` touches nothing else — no ambiguity can arise.

**Why `dim_geo` is not related to `dim_customer`.** It is tempting: both have a
state. But `dim_customer` is already related to both facts, so adding
`dim_geo → dim_customer` creates two paths from `dim_geo` to `fact_sales` and
Power BI would deactivate one of them. Geography reaches the facts directly.

**Why the 1:1 relationships have unmatched rows, and why that is fine.**
`dim_customer` holds every customer; `vw_rfm` and `vw_customer_ltv` hold only
customers with at least one non-cancelled order. In the real dataset that is a
gap of a few thousand rows. Power BI shows the unmatched side as blank, which is
the truthful answer — those people have no RFM segment because they never
bought anything. `Repeat Customer %` handles it explicitly by using
`lifetime_orders >= 1` as its denominator.

**Why `vw_cohort` floats.** Its grain is cohort-month × month-index, which does
not join to a daily date table without lying. The retention matrix carries its
own cohort slicer instead. `vw_category_pareto` floats for a different reason —
the `Cumulative Revenue %` measure recomputes the Pareto live off `fact_sales`,
so the SQL version exists to cross-check the DAX, not to feed it.

### Mark the date table

`dim_date` → **Table tools → Mark as date table** → date column `date`.

Nothing in section 02 of `dax/measures.md` works until this is done — `TOTALYTD`
and `SAMEPERIODLASTYEAR` silently return blanks against an unmarked table.

### Model housekeeping

Skipping this is what makes a portfolio model look unfinished.

**Sort-by columns** (Column tools → Sort by column):

| Column | Sort by |
|---|---|
| `dim_date[month_name]`, `dim_date[month_short]` | `month_number` |
| `dim_date[year_month_label]` | `year_month` |
| `dim_date[day_name]`, `dim_date[day_short]` | `day_of_week` |
| `vw_rfm[rfm_segment]` | `segment_rank` |
| `vw_cohort[cohort_month_label]` | `cohort_month_key` |
| `vw_cohort[month_index_label]` | `month_index` |
| `dim_customer[cohort_month_label]` | `cohort_month_key` |

**Summarize by → None** for every numeric column that is an identifier or a
score, or Power BI will happily offer you the *sum* of review scores:
`review_score`, `r_score`, `f_score`, `m_score`, `fm_score`, `month_index`,
`order_seq`, `revenue_rank`, `ltv_decile`, `date_key`, `year`, `month_number`,
`latitude`, `longitude`, `batch_id`.

**Data categories** on `dim_geo`: `map_location` → Place, `state_name` → State
or Province, `country` → Country, `latitude` → Latitude, `longitude` →
Longitude.

**Hide** from report view: every `*_key`, `customer_id`, `order_item_key`,
`date_key`, `product_id`, `seller_id`, `review_score_oa`, `review_band_oa`,
`cohort_month_key`, `segment_rank`, and all of `rls_user_region`.

Those `_oa` columns are order attributes carried on the item-grain fact for
filtering only. Hiding them stops anyone dropping `review_score_oa` into a chart
and getting a per-item-weighted average.

**Formats**: money `R$ #,##0`; percentages `0.0%`; `delivery_days` and
`days_vs_promise` as whole numbers with a thousands separator.

Now add the measures from `dax/measures.md`.

## 3.5 · Row-level security

Model view → **Manage roles**.

### Static role — the simple version

Role `Southeast`, table `dim_geo`:

```dax
[region] = "Southeast"
```

Fine for a demo, but it means one role per region, maintained by hand.

### Dynamic role — the one to show

Role `Regional Manager`, with a filter on **two** tables.

On `dim_geo`:

```dax
dim_geo[region] IN
    CALCULATETABLE (
        VALUES ( rls_user_region[region] ),
        rls_user_region[user_email] = USERPRINCIPALNAME ()
    )
```

On `dim_customer`:

```dax
dim_customer[customer_region] IN
    CALCULATETABLE (
        VALUES ( rls_user_region[region] ),
        rls_user_region[user_email] = USERPRINCIPALNAME ()
    )
```

On `rls_user_region` itself:

```dax
[user_email] = USERPRINCIPALNAME ()
```

Filtering `dim_customer` as well as `dim_geo` is the part people miss.
`dim_geo` is deliberately not related to `dim_customer` (see above), so a role
that only filters `dim_geo` locks down every revenue visual and leaves the RFM,
LTV and cohort visuals wide open — a customer list is exactly the thing regional
RLS is supposed to protect. Two filter expressions, one role, no ambiguity.

Adding a manager is then an `INSERT` into `mart.rls_user_region`, no model
change. That table has a `CHECK` constraint on the region name, because a typo
there gives someone an empty report that looks identical to a quiet month.

Test with **Manage roles → Test as role**, then assign real users under the
semantic model's **Security** page.

## 3.6 · Refresh

| What | When |
|---|---|
| n8n drip + mart refresh | every 15 min |
| Dataflow Gen2 → Lakehouse | 2×/day, offset ~10 min after an n8n run |
| Semantic model | 2×/day, ~15 min after the dataflow |

Chain them with a gap rather than stacking them on the hour. Each stage should
start after the previous one has actually finished.

## 3.7 · Surviving the trial expiry

The Fabric trial ends after 60 days and the direct Postgres connection goes with
it. Decide which of these you want before that happens:

**Do nothing.** The report keeps working; the data stops updating and freezes at
whatever the last refresh loaded. Perfectly acceptable for a portfolio piece —
just say so in the README rather than letting someone discover a stale date.

**Add a file hop (recommended, and free).** Add one node to the n8n workflow that
writes each mart view to CSV into a OneDrive for Business or SharePoint folder on
a schedule. Power BI Service builds a semantic model straight from a
OneDrive/SharePoint folder and refreshes it with no gateway and no Fabric
capacity — it works on a Pro licence, and in My Workspace on a free one. Slower
and less elegant than a live SQL connection, but it is the version that is still
alive next year. Set this up *before* the trial ends so you can prove both paths
work.

**Pay for it.** An F2 capacity is the smallest that keeps Dataflow Gen2. Not
worth it for a portfolio.
