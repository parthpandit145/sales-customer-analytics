# 1 · Cloud Postgres on Neon

Why Neon over the alternatives, since the choice shows up in interviews:

| | Neon | Supabase | Aiven |
|---|---|---|---|
| Free storage | 0.5 GB | 0.5 GB | 5 GB |
| Idle behaviour | scales to zero, **wakes on connect** | **pauses after ~7 days, manual restore** | always on, small instance |
| Public connection string | yes | yes | yes |
| Card required | no | no | no |

The deciding factor is the idle behaviour. A portfolio project gets opened
sporadically, weeks apart, often by someone who is not you. Supabase's free
tier pauses a project after about a week of inactivity and needs a manual
restore from the dashboard, so the dashboard a recruiter clicks would be dead.
Neon suspends compute but resumes automatically on the next connection.

The cost is 0.5 GB of storage, which this project stays inside by aggregating
the geolocation table at load time (see `scripts/02_load_seed.sh`).

## Steps

1. Sign up at **neon.tech** (GitHub or Google login, no card).
2. **Create project** and name it `olist-analytics`. Pick the region closest to
   you; the Fabric capacity's region matters more for refresh speed than yours,
   so if you know your Fabric home region, match it.
3. **Dashboard → Connect** gives you the connection string. Copy **both**
   variants. Neon shows a direct endpoint and a pooled one (the host with
   `-pooler` in it):

   ```
   postgresql://neondb_owner:PASSWORD@ep-xxxx.eu-central-1.aws.neon.tech/neondb?sslmode=require
   postgresql://neondb_owner:PASSWORD@ep-xxxx-pooler.eu-central-1.aws.neon.tech/neondb?sslmode=require
   ```

   Use the **direct** endpoint for the bulk CSV load (`COPY` through a pooler is
   slower and more likely to time out) and the **pooled** endpoint for n8n and
   Power BI, which open and close many short connections.

4. Save both into `scripts/.env` (copy `scripts/.env.example`). That file is
   gitignored. The connection string contains your password, so it must never
   reach the repo.

5. Install `psql` locally if you do not have it:

   ```bash
   brew install libpq && brew link --force libpq
   ```

## Then run

```bash
scripts/00_download_data.sh   # Olist CSVs from Kaggle into ./data
scripts/01_setup_db.sh        # schemas, tables, functions, views
scripts/02_load_seed.sh       # bulk-load the CSVs into the seed schema
```

At this point `seed.*` holds the full source and `raw.*` is empty. That is
correct: filling `raw` is the pipeline's job, not the loader's.

## Things that will bite you

**Cold starts.** Neon suspends compute after ~5 minutes idle. The first query
after a suspension takes a second or two. Harmless for the dashboard, but if a
Power BI refresh is the very first thing to touch a cold database it can time
out. Schedule the semantic model refresh a few minutes *after* an n8n run so the
compute is already awake.

**Storage.** The free tier is 512 MB. Loaded and fully dripped, this project
sits at **272 MB**:

| Schema | Size |
|---|---|
| `raw` (landing zone) | 136 MB |
| `seed` (source copy) | 126 MB |
| `ops` (telemetry) | < 1 MB |

Check it with:

```sql
SELECT pg_size_pretty(pg_database_size(current_database()));
```

```sql
SELECT n.nspname, pg_size_pretty(sum(pg_total_relation_size(c.oid)))
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r','m') GROUP BY 1 ORDER BY 2 DESC;
```

Two things to know before you add anything:

The headroom is real but not unlimited, and **`REFRESH MATERIALIZED VIEW` needs
transient space equal to the object being refreshed**, because it builds the new copy
before dropping the old one. An earlier version of this project materialised the
mart layer, which pushed the database to 435 MB and then failed mid-refresh with
`could not extend file because project size limit (512 MB) has been exceeded`.
That is why there is no materialised layer now; the reasoning is in the header of
`sql/08_post_batch.sql`.

The obvious-looking saving is not one. The Portuguese review comment bodies look
like the biggest column in the database, but Postgres TOASTs and compresses them
down to **2.8 MB** total, so dropping them buys you almost nothing. The genuinely
large objects are `seed.orders` (35 MB) and `raw.orders` (33 MB), which are large
because of their indexes, not their text.

**SSL is mandatory.** Neon rejects unencrypted connections. Every connection
string needs `sslmode=require`, and in Power BI and n8n the encryption toggle
must be on.
