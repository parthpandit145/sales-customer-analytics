-- =============================================================================
-- 04_dim_date.sql
-- The date dimension. Built in SQL so Power BI never needs CALENDARAUTO().
--
-- Two rules a date table has to satisfy for DAX time intelligence to work:
--   1. contiguous -- no gaps, one row per day
--   2. whole years -- Jan 1 to Dec 31 on both ends
-- Both are enforced by deriving the bounds from seed.orders (the full source,
-- which does not change while the drip job runs) rather than from raw.orders
-- (which grows batch by batch and would reshape the table mid-project).
-- =============================================================================

CREATE OR REPLACE VIEW mart.dim_date AS
WITH bounds AS (
    SELECT
        coalesce(date_trunc('year', min(ops.safe_ts(o.order_purchase_timestamp)))::date,
                 date '2016-01-01') AS d_from,
        coalesce((date_trunc('year', max(ops.safe_ts(o.order_purchase_timestamp)))
                  + interval '1 year - 1 day')::date,
                 date '2018-12-31') AS d_to
    FROM seed.orders o
),
days AS (
    SELECT generate_series(b.d_from, b.d_to, interval '1 day')::date AS d
    FROM bounds b
)
SELECT
    to_char(d, 'YYYYMMDD')::int                       AS date_key,
    d                                                 AS date,

    extract(year    FROM d)::int                      AS year,
    extract(quarter FROM d)::int                      AS quarter,
    'Q' || extract(quarter FROM d)::int               AS quarter_name,
    extract(year FROM d)::int || ' Q' || extract(quarter FROM d)::int AS year_quarter,

    extract(month FROM d)::int                        AS month_number,
    to_char(d, 'FMMonth')                             AS month_name,
    to_char(d, 'Mon')                                 AS month_short,
    to_char(d, 'YYYYMM')::int                         AS year_month,      -- sort key
    to_char(d, 'Mon YYYY')                            AS year_month_label,
    date_trunc('month', d)::date                      AS month_start,
    (date_trunc('month', d) + interval '1 month - 1 day')::date AS month_end,

    extract(week FROM d)::int                         AS iso_week,
    to_char(d, 'IYYY-"W"IW')                          AS iso_year_week,
    date_trunc('week', d)::date                       AS week_start,

    extract(day  FROM d)::int                         AS day_of_month,
    extract(doy  FROM d)::int                         AS day_of_year,
    extract(isodow FROM d)::int                       AS day_of_week,     -- 1 = Monday
    to_char(d, 'FMDay')                               AS day_name,
    to_char(d, 'Dy')                                  AS day_short,

    (extract(isodow FROM d) >= 6)                     AS is_weekend,
    (d = (date_trunc('month', d) + interval '1 month - 1 day')::date) AS is_month_end,
    (d = date_trunc('year', d)::date)                 AS is_year_start,

    -- Useful for "same period last year" sanity checks in the report
    (d - interval '1 year')::date                     AS date_ly
FROM days;

COMMENT ON VIEW mart.dim_date IS
    'Contiguous whole-year date table. Mark as date table in Power BI on [date].';
