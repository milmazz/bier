-- LIVE LOADER INPUT — not a historical fragment. `mix bier.fixtures.load`
-- re-loads this file to build the real `rpc` area schema by remapping the
-- word-boundary token `test` -> `rpc` (see lib/mix/tasks/bier.fixtures.load.ex).
-- INVARIANTS an edit must preserve: every object stays `test`-qualified, and
-- no string literal may contain the bare lowercase token `test` (the remap
-- would corrupt it). Edit only in reviewed commits; workflow agents route new
-- rpc fixture objects through rpc.delta.sql instead (see README.md here).
--
-- Conformance fixtures for the RPC (/rpc/<fn>) feature area.
--
-- Self-contained subset of PostgREST's test/spec/fixtures/schema.sql, limited to
-- the routines exercised by spec/conformance/cases/14xx_*.yaml. All objects live
-- in schema `test`, which is the exposed (db-schemas) schema for these cases.
--
-- Upstream source: https://github.com/PostgREST/postgrest/blob/v14.12/test/spec/fixtures/schema.sql
-- Loads cleanly on PostgreSQL 14/15/16.

DROP SCHEMA IF EXISTS test CASCADE;
CREATE SCHEMA test;
SET search_path = test, public;

-- ---------------------------------------------------------------------------
-- Backing tables/data for SETOF and table-valued returns
-- ---------------------------------------------------------------------------

CREATE TABLE test.items (
  id bigint PRIMARY KEY
);
INSERT INTO test.items (id)
  SELECT generate_series(1, 15);

CREATE TABLE test.clients (
  id integer PRIMARY KEY,
  name text NOT NULL
);
INSERT INTO test.clients (id, name) VALUES (1, 'Microsoft'), (2, 'Apple');

CREATE TABLE test.projects (
  id integer PRIMARY KEY,
  name text NOT NULL,
  client_id integer REFERENCES test.clients(id)
);
INSERT INTO test.projects (id, name, client_id) VALUES
  (1, 'Windows 7', 1),
  (2, 'Windows 10', 1),
  (3, 'IOS', 2),
  (4, 'OSX', 2),
  (5, 'Orphan', NULL);

-- ---------------------------------------------------------------------------
-- SETOF / scalar / domain / composite returns
-- ---------------------------------------------------------------------------

-- SETOF table type; STABLE -> callable via GET (read-only tx).
-- schema.sql#L214
CREATE FUNCTION test.getitemrange(min bigint, max bigint) RETURNS SETOF test.items
  LANGUAGE sql STABLE
  AS $$ SELECT * FROM test.items WHERE id > min AND id <= max; $$;

-- SETOF table type with no args; STABLE.
-- schema.sql#L1037 (volatility relaxed to STABLE so GET is allowed in this fixture)
CREATE FUNCTION test.getallprojects() RETURNS SETOF test.projects
  LANGUAGE sql STABLE
  AS $$ SELECT * FROM test.projects; $$;

-- SETOF table type taking an id; STABLE -> GET-callable.
-- schema.sql#L1019 (upstream is VOLATILE; relaxed to STABLE so the GET
-- "select works on the first level" case (1422) can invoke it via GET).
CREATE FUNCTION test.getproject(id int) RETURNS SETOF test.projects
  LANGUAGE sql STABLE
  AS $$ SELECT * FROM test.projects WHERE id = $1; $$;

-- scalar int return.
-- schema.sql#L1862
CREATE FUNCTION test.add_them(a integer, b integer) RETURNS integer
  LANGUAGE sql IMMUTABLE
  AS $$ SELECT a + b; $$;

-- scalar text return.
-- schema.sql#L434
CREATE FUNCTION test.sayhello(name text) RETURNS text
  LANGUAGE sql IMMUTABLE
  AS $$ SELECT 'Hello, ' || name; $$;

-- no-parameter proc returning scalar text.
-- schema.sql#L225
CREATE FUNCTION test.noparamsproc() RETURNS text
  LANGUAGE sql IMMUTABLE
  AS $$ SELECT a FROM (VALUES ('Return value of no parameters procedure.')) s(a); $$;

-- SETOF integer.
-- schema.sql#L1086
CREATE FUNCTION test.ret_setof_integers() RETURNS SETOF integer
  LANGUAGE sql IMMUTABLE
  AS $$ VALUES (1), (2), (3); $$;

-- array return (single scalar array, not SETOF).
-- schema.sql#L1074
CREATE FUNCTION test.ret_array() RETURNS integer[]
  LANGUAGE sql IMMUTABLE
  AS $$ SELECT '{1,2,3}'::integer[]; $$;

-- SETOF that yields zero rows.
-- schema.sql#L479
CREATE FUNCTION test.test_empty_rowset() RETURNS SETOF integer
  LANGUAGE sql IMMUTABLE
  AS $$ SELECT null::int FROM (SELECT 1) a WHERE false; $$;

-- void return.
-- schema.sql#L1129
CREATE FUNCTION test.ret_void() RETURNS void LANGUAGE sql AS '';

-- composite type return (exposed schema).
-- schema.sql#L1105
CREATE TYPE test.point_2d AS (x integer, y integer);
CREATE FUNCTION test.ret_point_2d() RETURNS test.point_2d
  LANGUAGE sql IMMUTABLE
  AS $$ SELECT row(10, 5)::test.point_2d; $$;

-- ---------------------------------------------------------------------------
-- OUT / INOUT / TABLE returns
-- ---------------------------------------------------------------------------

-- single OUT param -> single object.
-- schema.sql#L1249
CREATE FUNCTION test.single_out_param(num int, OUT num_plus_one int)
  LANGUAGE sql IMMUTABLE
  AS $$ SELECT num + 1; $$;

-- single INOUT param -> single object.
-- schema.sql#L1261
CREATE FUNCTION test.single_inout_param(INOUT num int)
  LANGUAGE sql IMMUTABLE
  AS $$ SELECT num + 1; $$;

-- many OUT params -> single object with many keys.
-- schema.sql#L1257
CREATE FUNCTION test.many_out_params(OUT my_json json, OUT num int, OUT str text)
  LANGUAGE sql IMMUTABLE
  AS $$ SELECT '{"a": 1, "b": "two"}'::json, 3, 'four'::text; $$;

-- single-column TABLE return.
-- schema.sql#L1269
CREATE FUNCTION test.single_column_table_return() RETURNS TABLE (a text)
  LANGUAGE sql IMMUTABLE
  AS $$ SELECT 'A'::text; $$;

-- multi-column TABLE return.
-- schema.sql#L1273
CREATE FUNCTION test.multi_column_table_return() RETURNS TABLE (a text, b text)
  LANGUAGE sql IMMUTABLE
  AS $$ SELECT 'A'::text, 'B'::text; $$;

-- ---------------------------------------------------------------------------
-- VARIADIC and DEFAULT args
-- ---------------------------------------------------------------------------

-- VARIADIC text[] with default; supports GET repeated params and POST array.
-- schema.sql#L1277
CREATE FUNCTION test.variadic_param(VARIADIC v text[] DEFAULT '{}')
  RETURNS text[]
  LANGUAGE sql IMMUTABLE
  AS $$ SELECT v; $$;

-- all args have DEFAULT values.
-- schema.sql#L1343
CREATE FUNCTION test.three_defaults(a int DEFAULT 1, b int DEFAULT 2, c int DEFAULT 3)
  RETURNS int
  LANGUAGE sql IMMUTABLE
  AS $$ SELECT a + b + c; $$;

-- ---------------------------------------------------------------------------
-- Volatile proc (mutating) -> rejected on GET
-- ---------------------------------------------------------------------------

-- VOLATILE proc; GET runs it in a read-only tx and Postgres raises 25006.
-- schema.sql#L448
CREATE SEQUENCE test.callcounter_count START 1;
CREATE FUNCTION test.callcounter() RETURNS bigint
  LANGUAGE sql VOLATILE
  AS $$ SELECT nextval('test.callcounter_count'); $$;

-- ---------------------------------------------------------------------------
-- Overloaded functions (same name, different argument signatures)
-- ---------------------------------------------------------------------------
-- PostgREST dispatches by the supplied arguments. overloaded() -> [1,2,3],
-- overloaded(a,b) -> a+b, overloaded(a,b,c) -> a||b||c.
-- schema.sql#L1347, schema.sql#L1355, schema.sql#L1359
CREATE FUNCTION test.overloaded() RETURNS SETOF int
  LANGUAGE sql IMMUTABLE
  AS $$ VALUES (1), (2), (3); $$;

CREATE FUNCTION test.overloaded(a int, b int) RETURNS int
  LANGUAGE sql IMMUTABLE
  AS $$ SELECT a + b; $$;

CREATE FUNCTION test.overloaded(a text, b text, c text) RETURNS text
  LANGUAGE sql IMMUTABLE
  AS $$ SELECT a || b || c; $$;

-- ---------------------------------------------------------------------------
-- Single unnamed json/jsonb parameter (NOT the deprecated Prefer:params header)
-- ---------------------------------------------------------------------------
-- A function with a single UNNAMED json parameter receives the ENTIRE POST body
-- as that argument. A function with a single NAMED json parameter does NOT, so
-- a top-level body that does not match its named params yields PGRST202.
-- schema.sql#L2355, schema.sql#L2360
CREATE FUNCTION test.unnamed_json_param(json) RETURNS json
  LANGUAGE sql IMMUTABLE
  AS $$ SELECT $1; $$;

CREATE FUNCTION test.named_json_param(data json) RETURNS json
  LANGUAGE sql IMMUTABLE
  AS $$ SELECT data; $$;

-- ---------------------------------------------------------------------------
-- RAISE error -> HTTP status mapping
-- ---------------------------------------------------------------------------

-- RAISE SQLSTATE PT402 maps to HTTP 402 with message/details/hint.
-- schema.sql#L1289
CREATE FUNCTION test.raise_pt402() RETURNS void
  LANGUAGE plpgsql
  AS $$
  BEGIN
    RAISE sqlstate 'PT402' USING message = 'Payment Required',
                                 detail = 'Quota exceeded',
                                 hint = 'Upgrade your plan';
  END;
  $$;
