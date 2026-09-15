# 2 · The n8n ingestion pipeline

## What it does

A scheduled workflow moves **500 orders every 15 minutes** from `seed` into
`raw`, together with their items, payments, reviews and customer record. It then
refreshes planner statistics and runs thirteen data-quality assertions. Any
row it refuses lands in `ops.load_errors` with the reason and the original
payload. Any hard failure stops the run loudly.

Draining the full 99k-order feed takes about two days of wall clock — which is
the point. A bulk load is a one-time script; a drip is a pipeline you can watch,
break, and show running.

## Why the SQL lives in a function, not in nodes

`ops.ingest_next_batch()` does the row-level work. n8n owns scheduling, retries,
branching and alerting. That split is deliberate:

- set-based work belongs in the database — twenty n8n nodes doing per-row
  inserts would be slower and untestable
- the logic ends up in version control as SQL, reviewable in a pull request
- the whole batch is one transaction, so a mid-batch failure leaves no half-loaded order
- you can run it by hand (`scripts/03_drip.sh`) without n8n running at all

## Setup

1. **Credential** — n8n → Credentials → New → Postgres:

   | Field | Value |
   |---|---|
   | Host | `ep-xxxx-pooler.REGION.aws.neon.tech` |
   | Database | `neondb` |
   | User / Password | from Neon |
   | Port | `5432` |
   | SSL | **Enable** (`require`) |

   Name it `Neon - Olist`.

2. **Import** `n8n/olist_drip_ingest.json` (Workflows → ⋯ → Import from file).

3. Open each Postgres node and re-pick the credential. The exported JSON carries
   a placeholder credential id, not a secret — that is intentional, and it means
   every node needs one click after import.

4. Run it once with the **Run Once (Manual)** trigger and confirm the output:

   ```
   batch_id | orders_attempted | rows_loaded | rows_rejected | status
   ```

5. Activate the workflow to start the schedule.

## The flow

```
Every 15 min ─┐
              ├─► Config ─► Ingest Batch ─┬─► New Orders? ─┬─► Refresh Statistics ─► DQ Checks ─► Filter failures ─► Fail The Run
Run Once ─────┘                          │                └─► Feed Drained (no-op)
                                         └─(error)────────────────────────────────────────► Shape Error ─► ops.load_errors
```

Three things worth pointing at in an interview:

**The retry is safe because the job is idempotent.** `Ingest Batch` retries three
times. That is only sound because the function reads from a stored watermark and
every insert is `ON CONFLICT DO NOTHING` — a retried batch re-processes the same
window and changes nothing. Retrying a non-idempotent load is how you get
duplicate revenue.

**Rejects are data, not exceptions.** A row with an unparseable price does not
kill the batch and does not vanish. It goes to `ops.load_errors` with its
payload, the batch is marked `partial`, and `mart.vw_load_errors` surfaces it in
the report. The reject *rate* is itself a monitored metric.

**Warnings and errors are separated.** Thirteen checks run after each batch. The
two `warn` checks (payment gaps, unknown categories) are expected to be non-zero
— vouchers genuinely make payments differ from item totals — so they are
recorded but do not stop the pipeline. Only `error` severity does.

## Watching it

```sql
SELECT * FROM mart.vw_pipeline_health LIMIT 10;
SELECT error_type, count(*) FROM ops.load_errors GROUP BY 1 ORDER BY 2 DESC;
SELECT * FROM ops.ingest_watermark;
SELECT * FROM ops.run_dq_checks();
```

## Fast-forwarding

Waiting two days is fine for the story and annoying for development. To drain
the feed immediately, using the exact same function and watermark:

```bash
scripts/03_drip.sh
```

To start over:

`sql/99_reset.sql` empties the landing zone and rewinds the watermark, leaving
`seed` alone so you do not have to re-load the CSVs.

To wipe and replay from scratch, use the script that says what it does:

```bash
psql "$DATABASE_URL" -f sql/99_reset.sql
```
