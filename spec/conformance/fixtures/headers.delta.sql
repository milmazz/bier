-- headers area fixture delta (PostgREST v14.12 -> v16.0 spec re-sync).
--
-- Write channel per spec/conformance/fixtures/README.md: NEW objects only. The
-- Fixture Consolidator folds this into ../fixtures.sql, verifies the load, then
-- empties this file. Nothing here duplicates DDL that ../fixtures.sql already
-- has (verified with `\df test.*vary*` against a freshly loaded bier_test: no
-- match).
--
-- Needed by case 1576 (headers/vary/guc-override).
--
-- v16.0 adds a default `Vary: Accept, Prefer, Range` response header, appended
-- only when the response does not already carry a Vary:
--   [varyHeader | not $ varyHeaderPresent hdrs]
--   https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/src/library/PostgREST/App.hs#L253
-- Upstream exercises the override with a `db-pre-request` function:
--   fixture: https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/fixtures/schema.sql#L3875
--   test:    https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/Feature/HttpHeaderSpec.hs#L15
-- The conformance runner cannot set `db-pre-request` per case, so the same
-- `response.headers` GUC is set from an RPC instead. That is the mechanism the
-- docs themselves document for overriding Vary, and the payload below is the
-- docs' own example verbatim:
--   https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/docs/references/api/vary_header.rst#L14
-- The suppression check inspects the final response header list (GUC headers are
-- merged in first, Response.hs#L240) and is indifferent to which SQL wrote it.
--
-- Created in schema `test` (so case 1576 carries `schema: test`) because the
-- `headers` area schema is built by the loader from the human-owned
-- `headers.sql` live input, which workflow agents may not edit. The routine
-- shape mirrors the existing test.get_int_and_guc_headers so the scalar body
-- rendering matches case 1566.

CREATE FUNCTION test.get_vary_header_override() RETURNS integer
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM set_config('response.headers', '[{"Vary": "Accept, Prefer, X-Test-Vary"}]', true);
  RETURN 1;
END
$$;

GRANT EXECUTE ON FUNCTION test.get_vary_header_override() TO postgrest_test_anonymous;
