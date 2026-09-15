-- =============================================================================
-- 11_rls_mapping.sql
-- Backing table for DYNAMIC row-level security in Power BI.
--
-- Static RLS (one role per region, hard-coded) is easy but does not scale: five
-- regions means five roles to maintain by hand. Dynamic RLS keeps the mapping in
-- the database, where it belongs, and uses a single role whose filter resolves
-- against USERPRINCIPALNAME(). Adding a regional manager becomes an INSERT.
-- =============================================================================

CREATE TABLE IF NOT EXISTS mart.rls_user_region (
    user_email  text NOT NULL,
    region      text NOT NULL,         -- must match mart.dim_geo.region exactly
    role_label  text,
    PRIMARY KEY (user_email, region)
);

COMMENT ON TABLE mart.rls_user_region IS
    'Maps a Power BI login to the regions it may see. One row per user per region. A user with no rows sees nothing.';

-- Replace these with your own tenant's addresses. The pattern to demonstrate:
-- a national role holds every region, regional roles hold one.
TRUNCATE mart.rls_user_region;
INSERT INTO mart.rls_user_region (user_email, region, role_label) VALUES
 ('national.director@example.com', 'Southeast',    'National'),
 ('national.director@example.com', 'South',        'National'),
 ('national.director@example.com', 'Northeast',    'National'),
 ('national.director@example.com', 'North',        'National'),
 ('national.director@example.com', 'Central-West', 'National'),
 ('sudeste.manager@example.com',   'Southeast',    'Regional'),
 ('sul.manager@example.com',       'South',        'Regional'),
 ('nordeste.manager@example.com',  'Northeast',    'Regional');

-- Guard: a typo in `region` silently gives a manager an empty report, which is
-- indistinguishable from "no sales this month". Fail at load time instead.
DO $$
BEGIN
    ALTER TABLE mart.rls_user_region
        ADD CONSTRAINT ck_rls_region_valid
        CHECK (region IN ('North','Northeast','Central-West','Southeast','South'));
EXCEPTION WHEN duplicate_object THEN NULL;   -- already there, re-run is fine
END $$;

-- Import this alongside the dimensions. It relates to nothing in the model --
-- the RLS expression references it directly.
