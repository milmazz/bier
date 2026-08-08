-- Delta fixture for the "content_negotiation" feature area, PostgREST v16.0
-- re-sync. NEW objects only - nothing here duplicates DDL that already exists
-- in spec/conformance/fixtures.sql. The Fixture Consolidator folds this into
-- fixtures.sql and then empties this file.
--
-- Style matches fixtures.sql: custom media-type DOMAINs live in `public`
-- (see fixtures.sql L295-L297), the handler functions/aggregates live in `test`
-- and are written fully qualified.
--
-- Needed by:
--   case 1642  content_negotiation/custom-media-handler/vendored-not-overridable
--   case 1644  content_negotiation/custom-media-handler/table-aggregate
--   case 1646  content_negotiation/custom-media-handler/default-select-required
--
-- Upstream provenance:
--   https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/fixtures/schema.sql#L121
--   https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/fixtures/schema.sql#L122
--   https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/fixtures/schema.sql#L3522
--   https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/fixtures/schema.sql#L3535

-- -------------------------------------------------------------------------
-- (1) An override attempt on a VENDORED media type (case 1642).
--
-- PostgREST models a custom media type as a DOMAIN named after the mime and
-- its handler as an AGGREGATE whose stype is that domain. Registering one for
-- "application/vnd.pgrst.object" must have NO effect: negotiateContent matches
-- the vendored types before it ever consults the handler map, so the aggregate
-- below is dead weight by design. Mirrors upstream schema.sql "-- override
-- application/vnd.pgrst.object" (L3522-L3533): the sfunc returns NULL, so if an
-- implementation *did* wrongly dispatch to it the response body would be null
-- instead of the singular object - which is exactly what case 1642 detects.
-- -------------------------------------------------------------------------
CREATE DOMAIN public."application/vnd.pgrst.object" AS json;

CREATE OR REPLACE FUNCTION test.pgrst_obj_json_trans(
  state public."application/vnd.pgrst.object",
  next  anyelement
) RETURNS public."application/vnd.pgrst.object" AS $$
  SELECT NULL::public."application/vnd.pgrst.object";
$$ LANGUAGE sql;

CREATE AGGREGATE test.pgrst_obj_agg(anyelement) (
  initcond = '{"overridden": "true"}',
  stype    = public."application/vnd.pgrst.object",
  sfunc    = test.pgrst_obj_json_trans
);

-- -------------------------------------------------------------------------
-- (2) A custom media type handled for ONE relation (case 1644).
--
-- text/tab-separated-values is not a media type PostgREST knows, so it decodes
-- to MTOther: the response Content-Type carries no charset. The aggregate is
-- defined over the test.projects row type, so it is only negotiable on
-- /projects (and only with the default select, per the defaultSelect gate in
-- Plan/Negotiate.hs). Mirrors upstream schema.sql L3535-L3553.
--
-- Verified against a freshly loaded bier_test: for /projects?id=in.(1,2) the
-- aggregate yields "id\tname\tclient_id\n1\tWindows 7\t1\n2\tWindows 10\t1\n"
-- (47 bytes), byte-identical to the upstream assertion.
-- -------------------------------------------------------------------------
CREATE DOMAIN public."text/tab-separated-values" AS text;

CREATE OR REPLACE FUNCTION test.tsv_trans(state text, next test.projects)
RETURNS public."text/tab-separated-values" AS $$
  SELECT (
    state || next.id::text || E'\t' || next.name || E'\t' ||
    coalesce(next.client_id::text, '') || E'\n'
  )::public."text/tab-separated-values";
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION test.tsv_final(data public."text/tab-separated-values")
RETURNS public."text/tab-separated-values" AS $$
  SELECT (E'id\tname\tclient_id\n' || data)::public."text/tab-separated-values";
$$ LANGUAGE sql;

CREATE AGGREGATE test.tsv_agg(test.projects) (
  initcond  = '',
  stype     = public."text/tab-separated-values",
  sfunc     = test.tsv_trans,
  finalfunc = test.tsv_final
);
