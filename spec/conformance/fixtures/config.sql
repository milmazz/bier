-- Conformance fixtures for the CONFIG area (PostgREST v14.12)
--
-- Config is mostly a boot-time concern; only a few keys have HTTP-observable
-- effects (db-max-rows, server-cors-allowed-origins). Those cases reuse the
-- minimal `items` table from PostgREST's own fixtures.
-- Sources:
--   items table: https://raw.githubusercontent.com/PostgREST/postgrest/v14.12/test/spec/fixtures/schema.sql#L126
--   items data:  https://raw.githubusercontent.com/PostgREST/postgrest/v14.12/test/spec/fixtures/data.sql#L205
--
-- The PostgREST server under test is configured PER CASE via the `config`
-- block in each YAML (env vars / config keys). The cases that exercise HTTP
-- behavior assume:
--   db-schemas   = "test"   (bare paths resolve here)
--   db-anon-role = "postgrest_test_anonymous"
-- plus the per-case overrides documented in each case's `notes`.

BEGIN;

DROP ROLE IF EXISTS postgrest_test_anonymous;
CREATE ROLE postgrest_test_anonymous;

DROP SCHEMA IF EXISTS test CASCADE;
CREATE SCHEMA test;
GRANT USAGE ON SCHEMA test TO postgrest_test_anonymous;

-- ---------------------------------------------------------------------------
-- items: a single bigserial id column, 15 rows (1..15)
-- Mirrors test/spec/fixtures/schema.sql#L126 and data.sql#L205
-- ---------------------------------------------------------------------------
CREATE TABLE test.items (
    id bigserial primary key
);

INSERT INTO test.items (id)
SELECT g FROM generate_series(1, 15) AS g;

GRANT SELECT ON test.items TO postgrest_test_anonymous;

COMMIT;
