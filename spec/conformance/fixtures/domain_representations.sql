-- Conformance fixtures for the "domain_representations" feature area
-- (PostgREST v14.12 "Data representations").
--
-- Self-contained subset of PostgREST's own test fixtures, restricted to the
-- DOMAIN types, casts, functions, tables, view and seed data exercised by
-- spec/conformance/cases/1800..1849.
--
-- A "data representation" is a PostgreSQL DOMAIN over a base type plus a set of
-- registered casts that tell PostgREST how to (de)serialize a column of that
-- domain:
--   * CREATE CAST (<domain> AS json)  -- read out: domain value -> JSON
--   * CREATE CAST (json AS <domain>)  -- write in (JSON body): JSON -> domain
--   * CREATE CAST (text AS <domain>)  -- parse query-string filter values
-- When no `<domain> AS json` cast exists the column serializes with the base
-- type's default JSON rendering (see domain `devil_int` below).
--
-- Sources (PostgREST v14.12 test/spec/fixtures):
--   schema.sql: color domain+casts L3053-3073, isodate L3075-3092,
--               bytea_b64 L3096-3114, unixtz L3117-3135, monetary L3138-3154,
--               datarep_todos L3157, datarep_next_two_todos L3165,
--               datarep_todos_computed L3172, devil_int L3224, evil_friends L3227
--   data.sql:   datarep_todos L819-822, datarep_next_two_todos L825-826
--               (evil_friends has no seed rows upstream)
--
-- Loads into Postgres 14/15/16. PostgREST exposes schema "test" by default
-- (db-schemas = "test"). NOTE: the domains/casts here are created in `public`
-- exactly as upstream does (casts must live where the base/target types are),
-- while the tables/views live in `test`. search_path keeps both reachable.

DROP SCHEMA IF EXISTS test CASCADE;
CREATE SCHEMA test;
SET search_path = test, public, pg_catalog;

-- === color: a 24-bit RGB integer rendered as "#RRGGBB" =====================
DROP DOMAIN IF EXISTS public.color CASCADE;
CREATE DOMAIN public.color AS INTEGER CHECK (VALUE >= 0 AND VALUE <= 16777215);

CREATE OR REPLACE FUNCTION public.color(json) RETURNS public.color AS $$
  SELECT public.color($1 #>> '{}');
$$ LANGUAGE SQL IMMUTABLE;

CREATE OR REPLACE FUNCTION public.color(text) RETURNS public.color AS $$
  SELECT (('x' || lpad((CASE WHEN SUBSTRING($1::text, 1, 1) = '#' THEN SUBSTRING($1::text, 2) ELSE $1::text END), 8, '0'))::bit(32)::int)::public.color;
$$ LANGUAGE SQL IMMUTABLE;

CREATE OR REPLACE FUNCTION public."json"(public.color) RETURNS json AS $$
  SELECT
    CASE WHEN $1 IS NULL THEN to_json(''::text)
    ELSE to_json('#' || lpad(upper(to_hex($1)), 6, '0'))
  END;
$$ LANGUAGE SQL IMMUTABLE;

CREATE CAST (public.color AS json) WITH FUNCTION public."json"(public.color) AS IMPLICIT;
CREATE CAST (json AS public.color) WITH FUNCTION public.color(json) AS IMPLICIT;
CREATE CAST (text AS public.color) WITH FUNCTION public.color(text) AS IMPLICIT;

-- === isodate: timestamptz rendered with a trailing Z ========================
-- Intentionally has NO `text AS isodate` cast, to prove query-string parsing
-- does not fall back on the JSON parser.
DROP DOMAIN IF EXISTS public.isodate CASCADE;
CREATE DOMAIN public.isodate AS timestamp with time zone;

CREATE OR REPLACE FUNCTION public.isodate(json) RETURNS public.isodate AS $$
  SELECT public.isodate($1 #>> '{}');
$$ LANGUAGE SQL IMMUTABLE;

CREATE OR REPLACE FUNCTION public.isodate(text) RETURNS public.isodate AS $$
  SELECT (replace($1, 'Z', '+00:00')::timestamp with time zone)::public.isodate;
$$ LANGUAGE SQL IMMUTABLE;

CREATE OR REPLACE FUNCTION public."json"(public.isodate) RETURNS json AS $$
  SELECT to_json(replace(to_json($1)#>>'{}', '+00:00', 'Z'));
$$ LANGUAGE SQL IMMUTABLE;

CREATE CAST (public.isodate AS json) WITH FUNCTION public."json"(public.isodate) AS IMPLICIT;
CREATE CAST (json AS public.isodate) WITH FUNCTION public.isodate(json) AS IMPLICIT;
-- (no `text AS isodate` cast on purpose)

-- === bytea_b64: bytea rendered as unpadded base64 ===========================
DROP DOMAIN IF EXISTS public.bytea_b64 CASCADE;
CREATE DOMAIN public.bytea_b64 AS bytea;

CREATE OR REPLACE FUNCTION public.bytea_b64(json) RETURNS public.bytea_b64 AS $$
  SELECT public.bytea_b64($1 #>> '{}');
$$ LANGUAGE SQL IMMUTABLE;

CREATE OR REPLACE FUNCTION public.bytea_b64(text) RETURNS public.bytea_b64 AS $$
  -- allow unpadded base64
  SELECT decode($1 || repeat('=', 4 - (length($1) % 4)), 'base64')::public.bytea_b64;
$$ LANGUAGE SQL IMMUTABLE;

CREATE OR REPLACE FUNCTION public."json"(public.bytea_b64) RETURNS json AS $$
  SELECT to_json(translate(encode($1, 'base64'), E'\n', ''));
$$ LANGUAGE SQL IMMUTABLE;

CREATE CAST (public.bytea_b64 AS json) WITH FUNCTION public."json"(public.bytea_b64) AS IMPLICIT;
CREATE CAST (json AS public.bytea_b64) WITH FUNCTION public.bytea_b64(json) AS IMPLICIT;
CREATE CAST (text AS public.bytea_b64) WITH FUNCTION public.bytea_b64(text) AS IMPLICIT;

-- === unixtz: timestamptz rendered as integer epoch seconds ==================
DROP DOMAIN IF EXISTS public.unixtz CASCADE;
CREATE DOMAIN public.unixtz AS timestamp with time zone;

CREATE OR REPLACE FUNCTION public.unixtz(json) RETURNS public.unixtz AS $$
  SELECT public.unixtz($1 #>> '{}');
$$ LANGUAGE SQL IMMUTABLE;

CREATE OR REPLACE FUNCTION public.unixtz(text) RETURNS public.unixtz AS $$
  SELECT (to_timestamp($1::numeric)::public.unixtz);
$$ LANGUAGE SQL IMMUTABLE;

CREATE OR REPLACE FUNCTION public."json"(public.unixtz) RETURNS json AS $$
  SELECT to_json(extract(epoch from $1)::bigint);
$$ LANGUAGE SQL IMMUTABLE;

CREATE CAST (public.unixtz AS json) WITH FUNCTION public."json"(public.unixtz) AS IMPLICIT;
CREATE CAST (json AS public.unixtz) WITH FUNCTION public.unixtz(json) AS IMPLICIT;
CREATE CAST (text AS public.unixtz) WITH FUNCTION public.unixtz(text) AS IMPLICIT;

-- === monetary: numeric(17,2) rendered as a JSON string ======================
DROP DOMAIN IF EXISTS public.monetary CASCADE;
CREATE DOMAIN public.monetary AS numeric(17,2);

CREATE OR REPLACE FUNCTION public.monetary(json) RETURNS public.monetary AS $$
  SELECT public.monetary($1 #>> '{}');
$$ LANGUAGE SQL IMMUTABLE;

CREATE OR REPLACE FUNCTION public.monetary(text) RETURNS public.monetary AS $$
  SELECT ($1::numeric)::public.monetary;
$$ LANGUAGE SQL IMMUTABLE;

CREATE OR REPLACE FUNCTION public."json"(public.monetary) RETURNS json AS $$
  SELECT to_json($1::text);
$$ LANGUAGE SQL IMMUTABLE;

CREATE CAST (public.monetary AS json) WITH FUNCTION public."json"(public.monetary) AS IMPLICIT;
CREATE CAST (json AS public.monetary) WITH FUNCTION public.monetary(json) AS IMPLICIT;
CREATE CAST (text AS public.monetary) WITH FUNCTION public.monetary(text) AS IMPLICIT;

-- === devil_int: a domain WITHOUT any custom `AS json` cast ==================
-- Used to prove the default behaviour: with no registered representation, the
-- column serializes using the base type's (integer) plain JSON rendering.
DROP DOMAIN IF EXISTS public.devil_int CASCADE;
CREATE DOMAIN public.devil_int AS int DEFAULT 666;

-- === tables / view ==========================================================
CREATE TABLE test.datarep_todos (
  id bigint primary key,
  name text,
  label_color public.color default 0,
  due_at public.isodate default '2018-01-01'::date,
  icon_image public.bytea_b64,
  created_at public.unixtz default '2017-12-14 01:02:30'::timestamptz,
  budget public.monetary default 0
);

CREATE TABLE test.datarep_next_two_todos (
  id bigint primary key,
  first_item_id bigint references test.datarep_todos(id),
  second_item_id bigint references test.datarep_todos(id),
  name text
);

CREATE VIEW test.datarep_todos_computed as (
  SELECT id,
    name,
    label_color,
    due_at,
    (label_color / 2)::public.color as dark_color
  FROM test.datarep_todos
);

CREATE TABLE test.evil_friends(
  id   public.devil_int,
  name text
);

-- === seed data ==============================================================
INSERT INTO test.datarep_todos VALUES (1, 'Report', 0, '2018-01-02', '\x89504e470d0a1a0a0000000d4948445200000001000000010100000000376ef924000000001049444154789c62600100000000ffff03000000060005057bfabd400000000049454e44ae426082', '2017-12-14 01:02:30', 12.50); -- smallest possible PNG
INSERT INTO test.datarep_todos VALUES (2, 'Essay', 256, '2018-01-03', NULL, '2017-12-14 01:02:30', 100000000000000.13); -- a number which can't be represented by a 64-bit float
INSERT INTO test.datarep_todos VALUES (3, 'Algebra', 123456, '2018-01-01 14:12:34.123456');
INSERT INTO test.datarep_todos VALUES (4, 'Opus Magnum', NULL, NULL);

INSERT INTO test.datarep_next_two_todos VALUES (1, 2, 3, 'school related');
INSERT INTO test.datarep_next_two_todos VALUES (2, 1, 3, 'do these first');

-- evil_friends intentionally has NO seed rows. Upstream data.sql seeds no rows
-- for it; the only citable behavior (InsertSpec.hs#L572 "inserts a default on a
-- DOMAIN with default", case 1814) is a POST that relies on the devil_int DEFAULT
-- 666, not on any pre-existing rows.
