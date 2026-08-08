-- rpc area fixture delta (write channel; see spec/conformance/fixtures/README.md).
-- New objects only — the Fixture Consolidator folds this into
-- spec/conformance/fixtures.sql, verifies the load, then empties this file.
--
-- Added by the PostgREST v14.12 -> v16.0 spec re-sync.
--
-- v16.0 appended one new RPC test: a routine whose name is a PostgreSQL
-- reserved word must still be reachable at /rpc/<name>.
--   test:    https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/Feature/Query/RpcSpec.hs#L1497
--   fixture: https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/fixtures/schema.sql#L3881
--
-- Upstream defines it in schema `test` (the last `SET search_path = test,
-- pg_catalog;` in schema.sql is at L988, before this definition) and declares no
-- volatility, so it is VOLATILE by default. That is deliberate and load-bearing:
-- the conformance case invokes it with GET, which PostgREST runs in a read-only
-- transaction — a VOLATILE routine that performs no write must still succeed
-- (contrast case 1427, where nextval() raises 25006 -> 405).
--
-- It is created in `test` (not in the `rpc` area schema) because the `rpc`
-- schema is built by the loader from the human-owned `rpc.sql` live input, which
-- workflow agents may not edit; case 1440 therefore carries `schema: test`,
-- matching the default profile upstream uses.
CREATE FUNCTION test."true"() RETURNS boolean
    LANGUAGE sql
    AS $_$ select true; $_$;

GRANT EXECUTE ON FUNCTION test."true"() TO postgrest_test_anonymous;
