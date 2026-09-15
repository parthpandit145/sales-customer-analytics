# Runbook: from empty machine to a live report

Ordered. Each phase ends with something you can verify. Detail lives in `docs/`;
this file is the spine.

Roughly 2 to 3 hours end to end, most of it in Power BI.

---

## Phase 0 · Tooling ✅ done

`psql` (PostgreSQL 18.6) is installed via Homebrew and added to your `PATH` in
`~/.zshrc`. Docker and git were already there.

Open a **new terminal tab** so the PATH change takes effect, then confirm:

```bash
psql --version
```

---

## Phase 1 · Neon (you must do this part)

Account creation is on you; I can't sign up on your behalf.

1. Go to **neon.tech**, sign up with GitHub or Google. No card.
2. **Create project** → name `olist-analytics`. Any region.
3. **Dashboard → Connect**. Copy both connection strings: the plain one and
   the one whose host contains `-pooler`.
4. Create your env file:

```bash
cp scripts/.env.example scripts/.env
```

5. Open `scripts/.env` and paste the two strings in. Direct endpoint goes in
   `DATABASE_URL`, pooled in `DATABASE_URL_POOLED`.

`scripts/.env` is gitignored. It holds your database password, so it must never
be committed, and don't paste it into chat either.

**Verify:**

```bash
set -a && . scripts/.env && set +a && psql "$DATABASE_URL" -c "SELECT version();"
```

---

## Phase 2 · Data

Kaggle needs a sign-in, so grab the zip in a browser. No API token, no CLI.

1. Open <https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce>
2. Sign in, click **Download** (~45 MB). Leave it in `~/Downloads`.
3. Then:

```bash
scripts/00_download_data.sh
```

It finds the zip in `~/Downloads`, unpacks it, and lists the nine CSVs.

---

## Phase 3 · Build the database

```bash
scripts/01_setup_db.sh
```

Creates the five schema layers, tables, functions and every view. Safe to re-run.

```bash
scripts/02_load_seed.sh
```

Bulk-loads the nine CSVs into `seed` and aggregates the 1M-row geolocation table
down to one point per zip prefix. Two to five minutes depending on your
connection. It prints a row count per table at the end, and `orders` should be
99,441.

At this point `seed` holds the full source and `raw` is **empty**. That is
correct: filling `raw` is the pipeline's job.

---

## Phase 4 · Run the pipeline

Two options. Do the fast one first so you have data to model against.

**Fast-forward locally**, same function n8n calls, same watermark:

```bash
scripts/03_drip.sh
```

About 100 batches, roughly 45 seconds.

**Verify:**

```bash
set -a && . scripts/.env && set +a && psql "$DATABASE_URL" -c "SELECT check_name, status, observed FROM ops.run_dq_checks();"
```

All thirteen should read `pass`. If `customer_grain_collapsed` fails, stop and read
`docs/02-pipeline.md`. Nothing downstream is trustworthy until it passes.

**Then n8n** (the part that makes it a pipeline project rather than a script):

```bash
docker run -d --name n8n -p 5678:5678 -v n8n_data:/home/node/.n8n docker.n8n.io/n8nio/n8n
```

Open <http://localhost:5678>, create the local owner account, then follow
`docs/02-pipeline.md` §Setup: add the Postgres credential pointing at your
**pooled** Neon endpoint with SSL on, import `n8n/olist_drip_ingest.json`, and
re-pick the credential on each of the four Postgres nodes.

Screenshot the workflow canvas and a successful execution for the repo.

> A Docker n8n only runs while your Mac is on. That is fine for screenshots and
> for demonstrating the design. If you want it genuinely always-on later, n8n
> Cloud's free tier or a $5 VPS will do it, but don't let that block you now.

---

## Phase 5 · Superset on Preset Cloud

Full detail in `docs/06-superset.md`. The shape of it:

1. Create the read-only database role and connection URI:

```bash
scripts/04_superset_role.sh
```

2. Sign up at **preset.io** (free tier, no card) and create a workspace.
3. **Data → Databases → + Database → PostgreSQL**, choose **SQLAlchemy URI**,
   and paste the line from `scripts/.superset_uri`.
4. Create six datasets from the `mart` schema: `bi_sales`, `bi_orders`,
   `bi_customer`, `vw_cohort`, `vw_category_pareto`, `vw_pipeline_health`.
5. On `bi_sales` and `bi_orders`, set **Main Datetime Column** to
   `purchase_date`. No time-series chart types appear until you do.
6. Add the metrics from `docs/06-superset.md` §6.4.
7. Build the three dashboard tabs from §6.5.
8. Add the RLS rule from §6.6.

Step 5 is the one that silently blocks half the chart types if you skip it.

> Superset connects straight to Postgres. No dataflow, no lakehouse, no
> gateway, no capacity licence. The Power BI path is still documented in
> `docs/03-powerbi.md` if you want to come back to it.

---

## Phase 6 · Make it a portfolio piece

```bash
git init && git add -A && git commit -m "Sales & Customer Analytics: pipeline, SQL model, Power BI"
```

Push it to GitHub. Since there is no `.pbix`, **the repo is the artifact**, and
that's why the SQL is commented the way it is.

Then:

- Screenshots into `docs/img/`, then add a Screenshots section to the README.
- Run `psql "$DATABASE_URL" -f sql/10_insight_queries.sql` and fill the blanks in
  `docs/05-insights.md` with your own numbers.
- Put the Power BI Service link at the top of the README.
- Nothing expires. Superset on Preset's free tier and Neon's free tier both run
  indefinitely, so unlike the Fabric trial there is no clock on this dashboard.

---

## If something breaks

| Symptom | Cause |
|---|---|
| `psql: command not found` | new terminal tab, or `export PATH="/opt/homebrew/opt/libpq/bin:$PATH"` |
| `SSL connection required` | connection string is missing `?sslmode=require` |
| Load hangs or times out | you're on the `-pooler` host; use the direct one for `02_load_seed.sh` |
| First query after idle is slow | Neon cold start, ~1-2s, normal |
| `Repeat Customer %` shows 0.00% | wired to `customer_id`, not `customer_unique_id` |
| No time-series chart types offered | dataset Main Datetime Column not set |
| Superset percentage metric is always 0 | integer division, add `::numeric` to `COUNT(*)` |
| Storage near 0.5 GB | `docs/01-neon-setup.md` § Things that will bite you |
