-- ordering area fixture delta (PostgREST v16.0 re-sync).
--
-- Write channel per spec/conformance/fixtures/README.md: NEW objects only, to be
-- folded into ../fixtures.sql by the Fixture Consolidator, which then empties
-- this file. Nothing here duplicates DDL that fixtures.sql already has.
--
-- Needed by cases 1225 / 1226 (ordering by a json-path array index). Mirrors
-- upstream test/spec/fixtures/schema.sql `create table test.arrays` and
-- test/spec/fixtures/data.sql's two seed rows verbatim, so the expected bodies
-- are the upstream ones:
--   schema: https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/fixtures/schema.sql#L2500
--   data:   https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/fixtures/data.sql#L742
--
-- NOTE for the Consolidator: `test.arrays` is also the fixture the select/filters
-- areas would need for `select=numbers->0` / array-index filters. If another
-- area's delta adds the same table in this pass, keep ONE copy — the definition
-- and the seed rows below are the upstream ones and must not be diverged.

CREATE TABLE test.arrays (
  id           int primary key,
  numbers      int[],
  numbers_mult int[][]
);

INSERT INTO test.arrays (id, numbers, numbers_mult) VALUES
  (0, '{1,2,3}',    '{{1,2,3},{4,5,6},{7,8,9}}'),
  (1, '{11,12,13}', '{{11,12,13},{14,15,16},{17,18,19}}');
