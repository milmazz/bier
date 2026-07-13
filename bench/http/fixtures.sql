-- Benchmark fixtures for bench/http (Bier vs PostgREST).
-- Loaded by run.sh into a dedicated `bier_bench` database:
--   psql -v ON_ERROR_STOP=1 -d bier_bench -f bench/http/fixtures.sql
-- Idempotent: drops and recreates the bench schema on every load.
-- Deliberately independent of the frozen conformance fixtures in spec/.

\set ON_ERROR_STOP on

-- Both servers must render timestamptz identically in JSON bodies: Bier's
-- Postgrex pool pins its sessions to UTC, so pin every bier_bench session
-- (PostgREST's included) the same way. Without this the parity probe fails
-- on inserted_at's rendered offset whenever the machine TZ isn't UTC.
ALTER DATABASE bier_bench SET timezone TO 'UTC';

DROP SCHEMA IF EXISTS bench CASCADE;
CREATE SCHEMA bench;

-- Read target: ~100k rows, mixed column types, deterministic seed data
-- (generate_series, no random()) so every load is byte-identical.
CREATE TABLE bench.items (
  id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name text NOT NULL,
  value numeric(12, 2) NOT NULL,
  inserted_at timestamptz NOT NULL,
  active boolean NOT NULL,
  category text NOT NULL
);

INSERT INTO bench.items (name, value, inserted_at, active, category)
SELECT
  'item-' || g,
  ((g * 37) % 1000000)::numeric / 100,
  timestamptz '2026-01-01 00:00:00+00' + make_interval(secs => g),
  g % 3 <> 0,
  'category-' || lpad(((g % 20) + 1)::text, 2, '0')
FROM generate_series(1, 100000) AS g;

CREATE INDEX items_category_idx ON bench.items (category);

-- Write target for the mutation scenarios. Reset to a fixed 10k-row baseline
-- between measurement rounds via bench.reset_events() so table size never
-- favors whichever server ran first.
CREATE TABLE bench.events (
  id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  payload text NOT NULL,
  occurred_at timestamptz NOT NULL
);

-- The ~80k updates per M2 window trip the autovacuum threshold every write
-- stage; when the pass lands inside a measurement window it stalls the tail
-- of whichever server is being measured (p99 5ms -> ~50ms, p50/p90 flat).
-- TRUNCATE in reset_events() already restores identical table state before
-- every window, so autovacuum adds nothing but nondeterminism here; run.sh
-- ANALYZEs after each reset, which covers the stats autoanalyze would supply.
ALTER TABLE bench.events SET (autovacuum_enabled = off);

CREATE FUNCTION bench.reset_events() RETURNS void
LANGUAGE sql AS $$
  TRUNCATE bench.events RESTART IDENTITY;
  INSERT INTO bench.events (payload, occurred_at)
  SELECT
    'seed-' || g,
    timestamptz '2026-01-01 00:00:00+00' + make_interval(secs => g)
  FROM generate_series(1, 10000) AS g;
$$;

SELECT bench.reset_events();

-- Planner stats: TRUNCATE (inside reset_events) and bulk INSERT leave stale
-- stats until autoanalyze catches up; a mis-planned first burst of UPDATEs
-- can queue-spiral a cold server. Analyze eagerly.
ANALYZE bench.items;
ANALYZE bench.events;

-- Anonymous role shared by both servers. NOLOGIN: both servers connect as the
-- authenticator (the loading user) and SET ROLE per request, PostgREST-style.
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'bench_anon') THEN
    CREATE ROLE bench_anon NOLOGIN;
  END IF;
END
$$;

GRANT USAGE ON SCHEMA bench TO bench_anon;
GRANT SELECT ON bench.items TO bench_anon;
GRANT SELECT, INSERT, UPDATE ON bench.events TO bench_anon;
-- INSERT into an identity column needs the backing sequence.
GRANT USAGE ON ALL SEQUENCES IN SCHEMA bench TO bench_anon;

-- The connecting user must be able to SET ROLE bench_anon. :USER is psql's
-- built-in variable holding the connected user name.
GRANT bench_anon TO :"USER";
