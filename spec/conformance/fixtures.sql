-- ============================================================================
-- Bier conformance fixtures (CONSOLIDATED) — PostgREST v14.12 parity
-- ============================================================================
--
-- GENERATED FILE. Do not edit by hand. Regenerate from the per-area fragments
-- under spec/conformance/fixtures/*.sql with the Fixture Consolidator.
--
-- This file is the merge of the 17 per-area fragments under
-- spec/conformance/fixtures/*.sql. Those fragments were authored
-- independently and frequently re-create the same schemas/roles/tables (often
-- with slightly different shapes or seed data). This file dedupes them into a
-- single script that loads cleanly into a fresh database on PostgreSQL 14, 15
-- and 16 (verified against the locally available server; see VERIFICATION at
-- the bottom).
--
-- Source fragments, in dependency-friendly merge order:
--   1.  auth.sql                  (roles, jwt schema, postgrest schema, test.* RPCs)
--   2.  config.sql                (test.items)
--   3.  observability.sql         (schema observability.*)
--   4.  url_grammar.sql           (schemas test, تست, v1, v2; comma-name table)
--   5.  headers.sql               (schemas test, v1, v2, private, "SPECIAL ...")
--   6.  content_negotiation.sql   (test.* + custom media-type domains/aggregates)
--   7.  representations.sql       (test.* return=… cases)
--   8.  mutations.sql             (test.* mutating tables)
--   9.  errors.sql                (test.* SQLSTATE/RAISE objects)
--   10. filters.sql               (test.* filter tables)
--   11. operators.sql             (NOTE: authored unqualified; folded into test)
--   12. ordering.sql              (test.* ordering tables/computed cols)
--   13. pagination.sql            (test.* pagination tables/SETOF fns)
--   14. select.sql                (test.* embed/aggregate/one-to-one/computed-rel)
--   15. rpc.sql                   (test.* RPC routines incl. overloaded/json-param)
--   16. openapi.sql               (test.* OpenAPI doc-generation objects)
--   17. domain_representations.sql(public domains+casts; test.datarep_* tables)
--
-- ----------------------------------------------------------------------------
-- HOW COLLISIONS WERE RESOLVED
-- ----------------------------------------------------------------------------
-- Because nearly every fragment targets the same exposed schema (`test`) and
-- reuses the canonical PostgREST table names, one object is kept per qualified
-- name, choosing the richest superset that satisfies all consumers. Where two
-- fragments genuinely disagree on shape or seed data, the divergence is noted
-- inline and in the JSON `conflicts_resolved` summary returned by the agent.
--
-- Key decisions (see inline comments for detail):
--   * test.items        -> bigserial PK, rows 1..15. representations.sql seeded
--                          only 1..3 and rpc/auth used `bigint` PK; bigserial
--                          with 1..15 is a superset (still contains 1,2,3) and
--                          accepts explicit ids, so all consumers are satisfied.
--   * test.simple_pk    -> (k,extra) seeded ('xyyx','u'),('xYYx','v') — the
--                          shared seed of filters/operators/mutations/errors/
--                          content_negotiation. headers.sql used ('xyz'/'abc');
--                          its Content-Location cases only need a single-text-PK
--                          row, so the dominant seed is kept.
--   * test.no_pk        -> kept the seeded variant
--                          ((null,null),('1','0'),('2','0')); mutations /
--                          content_negotiation only INSERT into it, so the extra
--                          seed rows are inert for them.
--   * test.clients/projects -> projects FK to clients, 5 rows incl. Orphan
--                          (superset). headers/representations seeded 3 rows;
--                          content_negotiation/operators/select/pagination seed
--                          the same 5 rows. FK renamed to "client" (select.sql).
--   * test.complex_items-> settings jsonb (mutations' wider type vs operators'
--                          json), seeded with mutations' 3 rows incl. arr_data.
--   * test.tiobe_pls    -> rank smallint, seeded Java/C/Python (mutations'
--                          superset). headers/observability used fewer rows.
--   * test.entities     -> includes text_search_vector tsvector (filters/
--                          operators/select superset), 4 rows.
--   * test.menagerie    -> RENAMED collision: openapi.sql's rich type-mapping
--                          table is kept as test.menagerie; pagination.sql's
--                          single-column empty count table is preserved as
--                          test.menagerie_empty (it only needs an empty table to
--                          count and is referenced by no other object).
--   * test.authors_only -> auth.sql's functional (owner,secret) table is kept;
--                          openapi.sql's bare (secret) variant is dropped (its
--                          OpenAPI privilege cases only need the table to exist
--                          and be readable solely by postgrest_test_author).
--   * test.always_true(test.items) -> defined identically in select.sql AND
--                          ordering.sql; one definition kept.
--   * test.getproject(int) -> defined identically in rpc.sql (qualified, STABLE)
--                          AND content_negotiation.sql (unqualified); one STABLE
--                          definition kept so the GET case (1422) works.
--   * test.getallprojects() -> merged: STABLE (so rpc/content_negotiation GET
--                          works) AND ROWS 2019 (so pagination count=planned
--                          estimate holds). Single definition for all consumers.
--   * test.getitemrange(bigint,bigint) -> identical in rpc.sql + pagination.sql;
--                          one definition kept.
--   * test.sayhello / test.add_them -> defined in rpc.sql (test) and (for
--                          add_them/sayhello) also in content_negotiation /
--                          observability. observability copies live in their own
--                          schema (no collision); rpc.sql's test.* kept.
--   * test.raise_pt402() -> identical in rpc.sql + errors.sql; one kept.
--   * test.json_arr     -> filters' 10-row superset (select used first 2 rows).
--   * v1.children / v2.children -> url_grammar's seeded rows kept (headers
--                          created them empty).
--   * test.point_2d / observability.point_2d -> SAME unqualified name but in
--                          different schemas; both kept (no collision).
--   * NEW (changed fragments) — no cross-fragment name collisions:
--       select.sql: students/students_info (1-1 pk-as-fk), country/capital
--         (1-1 unique FK), designers/videogames + computed_designers/
--         computed_videogames (SETOF computed-relationship fns) — all unique.
--       rpc.sql: overloaded()/overloaded(int,int)/overloaded(text,text,text)
--         (three distinct signatures, legal in PG), unnamed_json_param(json),
--         named_json_param(json) — all unique to test schema.
--       url_grammar.sql: test.w_or_wo_comma_names — unique.
--   * Custom media-type domains ("application/json","*/*","application/vnd.geo2
--                          +json") and data-representation domains (color,
--                          isodate, bytea_b64, unixtz, monetary, devil_int) all
--                          live in `public` exactly as upstream; their names do
--                          not collide with each other or with any table.
-- ----------------------------------------------------------------------------

BEGIN;

-- ===========================================================================
-- 0. Extensions
-- ===========================================================================
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;  -- auth.sql (jwt.sign)

-- ===========================================================================
-- 1. Roles (auth.sql + config.sql + openapi.sql)
--    Idempotent create so the script is re-runnable on a shared cluster.
-- ===========================================================================
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'postgrest_test_anonymous') THEN
    CREATE ROLE postgrest_test_anonymous;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'postgrest_test_default_role') THEN
    CREATE ROLE postgrest_test_default_role;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'postgrest_test_author') THEN
    CREATE ROLE postgrest_test_author;
  END IF;
END $$;
-- The authenticator (PGUSER running PostgREST) must be able to SET ROLE to each:
--   GRANT postgrest_test_anonymous, postgrest_test_default_role,
--         postgrest_test_author TO <authenticator>;

-- ===========================================================================
-- 2. Schemas
-- ===========================================================================
DROP SCHEMA IF EXISTS test CASCADE;
CREATE SCHEMA test;

DROP SCHEMA IF EXISTS jwt CASCADE;
CREATE SCHEMA jwt;                                    -- auth.sql (pgjwt)

DROP SCHEMA IF EXISTS postgrest CASCADE;
CREATE SCHEMA postgrest;                              -- auth.sql (auth backing)

DROP SCHEMA IF EXISTS observability CASCADE;
CREATE SCHEMA observability;                          -- observability.sql

DROP SCHEMA IF EXISTS private CASCADE;
CREATE SCHEMA private;                                -- headers.sql (stuff view base)

CREATE SCHEMA IF NOT EXISTS v1;                       -- url_grammar / headers
CREATE SCHEMA IF NOT EXISTS v2;                       -- url_grammar / headers
CREATE SCHEMA IF NOT EXISTS "تست";                    -- url_grammar (unicode)
CREATE SCHEMA IF NOT EXISTS "SPECIAL ""@/\#~_-";      -- headers (special-named)

-- Reachable: test first, then public for shared casts/extensions.
SET search_path = test, public;

-- ===========================================================================
-- 3. Types (must precede tables/functions that use them)
-- ===========================================================================
CREATE TYPE public.jwt_token AS (token text);                 -- auth.sql
CREATE TYPE test.point_2d AS (x integer, y integer);          -- rpc.sql
CREATE TYPE test.complex AS (r double precision, i double precision);  -- ordering.sql
CREATE TYPE test.enum_menagerie_type AS ENUM ('foo', 'bar');  -- openapi.sql
CREATE TYPE observability.point_2d AS (x integer, y integer); -- observability.sql

-- ===========================================================================
-- 3b. Data-representation DOMAINs + casts (domain_representations.sql)
--     Live in `public` exactly as upstream (casts must live where the
--     base/target types are). Tables that use them live in `test` (section 4).
-- ===========================================================================

-- === color: a 24-bit RGB integer rendered as "#RRGGBB" =====================
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
-- Intentionally has NO `text AS isodate` cast.
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
CREATE DOMAIN public.devil_int AS int DEFAULT 666;

-- ===========================================================================
-- 3c. Custom media-type DOMAINs (content_negotiation.sql)
--     Domains live in `public`; the aggregate handlers depend on the ov_json
--     table and so are created in section 6 after that table exists.
-- ===========================================================================
CREATE DOMAIN public."application/vnd.geo2+json" AS jsonb;
CREATE DOMAIN public."application/json"          AS json;
CREATE DOMAIN public."*/*"                        AS bytea;

-- ===========================================================================
-- 4. Tables + inline FKs (parents declared before children)
-- ===========================================================================

-- ------------------- schema: postgrest (auth backing) ----------------------
CREATE TABLE postgrest.auth (
  id      text PRIMARY KEY,
  rolname name NOT NULL DEFAULT 'postgrest_test_author',
  pass    text NOT NULL
);

-- ------------------------------ schema: test -------------------------------

-- items: bigserial PK, rows 1..15 (superset of all consumers). auth/rpc used a
-- bare bigint PK and representations seeded only 1..3; bigserial accepts the
-- explicit ids and the 1..15 seed contains them, satisfying every consumer.
CREATE TABLE test.items (
  id bigserial primary key
);

-- has_count_column: anon-readable table (auth AudienceJwtSecretSpec).
CREATE TABLE test.has_count_column (count int);

-- private_table: empty table, no grants to anyone (auth.sql).
CREATE TABLE test.private_table ();

-- authors_only: owner/secret guarded table (auth.sql; richer than openapi's
-- bare (secret) variant, which is dropped — see header).
CREATE TABLE test.authors_only (
  owner  text NOT NULL DEFAULT current_setting('request.jwt.claims', true)::json->>'id',
  secret text NOT NULL,
  CONSTRAINT authors_only_pkey PRIMARY KEY (secret)
);

-- simple_pk: single text PK + extra. Seed ('xyyx','u'),('xYYx','v').
CREATE TABLE test.simple_pk (
  k     text NOT NULL PRIMARY KEY,
  extra text NOT NULL
);

-- no_pk: nullable text columns; seeded (null,null),('1','0'),('2','0').
CREATE TABLE test.no_pk (
  a character varying,
  b character varying
);

-- nullable_integer (operators.sql).
CREATE TABLE test.nullable_integer (
  a integer
);

-- only_pk: pk-only table (mutations upsert/PUT edge case).
CREATE TABLE test.only_pk (
  id integer NOT NULL PRIMARY KEY
);

-- articles: id/body/owner. mutations defaults owner to a constant; operators
-- seeds 'diogo'. owner is `name NOT NULL DEFAULT 'postgrest_test_anonymous'`
-- (mutations' deterministic default) — the operators seed supplies its own
-- owner so the default does not affect it.
CREATE TABLE test.articles (
  id    integer NOT NULL PRIMARY KEY,
  body  text,
  owner name NOT NULL DEFAULT 'postgrest_test_anonymous'
);

-- complex_items: settings jsonb (superset of operators/select/representations
-- json), arr_data, separator-named column.
CREATE TABLE test.complex_items (
  id bigint NOT NULL PRIMARY KEY,
  name text,
  settings jsonb,
  arr_data integer[],
  "field-with_sep" bigint NOT NULL DEFAULT 1
);

-- json_arr: 10-row superset (filters).
CREATE TABLE test.json_arr (
  id integer PRIMARY KEY,
  data json
);

-- json_table (filters/ordering).
CREATE TABLE test.json_table (
  data json
);

-- jsonb_test (filters).
CREATE TABLE test.jsonb_test (
  id integer PRIMARY KEY,
  data jsonb
);

-- ranges (filters/operators).
CREATE TABLE test.ranges (
  id integer PRIMARY KEY,
  range numrange
);

-- chores (filters/operators) — filters needs name+done columns (superset).
CREATE TABLE test.chores (
  id int PRIMARY KEY,
  name text,
  done bool
);

-- tsearch (operators).
CREATE TABLE test.tsearch (
  text_search_vector tsvector
);

-- entities / child_entities / grandchild_entities. entities includes the
-- tsvector column (filters/operators/select superset); grandchild_entities
-- includes the extra columns from filters (or_/and_starting_col, jsonb_col).
CREATE TABLE test.entities (
  id integer PRIMARY KEY,
  name text,
  arr integer[],
  text_search_vector tsvector
);

CREATE TABLE test.child_entities (
  id integer PRIMARY KEY,
  name text,
  parent_id integer REFERENCES test.entities(id)
);

CREATE TABLE test.grandchild_entities (
  id integer PRIMARY KEY,
  name text,
  parent_id integer REFERENCES test.child_entities(id),
  or_starting_col text,
  and_starting_col text,
  jsonb_col jsonb
);

-- clients / projects: FK pair, 5 rows incl. Orphan; FK renamed to "client".
CREATE TABLE test.clients (
  id integer PRIMARY KEY,
  name text NOT NULL
);

CREATE TABLE test.projects (
  id integer PRIMARY KEY,
  name text NOT NULL,
  client_id integer REFERENCES test.clients(id)
);
ALTER TABLE test.projects RENAME CONSTRAINT projects_client_id_fkey TO client;

-- tasks (one-to-many child of projects).
CREATE TABLE test.tasks (
  id integer PRIMARY KEY,
  name text NOT NULL,
  project_id integer REFERENCES test.projects(id)
);

-- users + users_tasks (m2m). PK ordering (task_id,user_id) matches the
-- pagination/select fixtures; ordering.sql's (user_id,task_id) is equivalent
-- for the relationship.
CREATE TABLE test.users (
  id integer PRIMARY KEY,
  name text NOT NULL
);

CREATE TABLE test.users_tasks (
  user_id integer NOT NULL REFERENCES test.users(id),
  task_id integer NOT NULL REFERENCES test.tasks(id),
  PRIMARY KEY (task_id, user_id)
);

-- project_invoices: aggregate-function cases (select.sql).
CREATE TABLE test.project_invoices (
  id int PRIMARY KEY,
  invoice_total numeric,
  project_id integer REFERENCES test.projects(id)
);

-- sites / big_projects / jobs / main_jobs: ambiguous-embed (select.sql).
CREATE TABLE test.big_projects (
  big_project_id serial PRIMARY KEY,
  name text
);

CREATE TABLE test.sites (
  site_id serial PRIMARY KEY,
  name text,
  main_project_id int NULL REFERENCES test.big_projects(big_project_id)
);
ALTER TABLE test.sites RENAME CONSTRAINT sites_main_project_id_fkey TO main_project;

CREATE TABLE test.jobs (
  job_id uuid,
  name text,
  site_id int NOT NULL REFERENCES test.sites(site_id),
  big_project_id int NOT NULL REFERENCES test.big_projects(big_project_id),
  PRIMARY KEY (job_id, site_id, big_project_id)
);

-- students / students_info: one-to-one via pk-as-fk (select.sql, NEW).
CREATE TABLE test.students (
  id integer,
  code text,
  name text,
  PRIMARY KEY (id, code)
);

CREATE TABLE test.students_info (
  id integer,
  code text,
  address text,
  PRIMARY KEY (id, code),
  FOREIGN KEY (code, id) REFERENCES test.students(code, id) ON DELETE CASCADE
);

-- country / capital: one-to-one via a UNIQUE-constraint FK (select.sql, NEW).
CREATE TABLE test.country (
  id integer PRIMARY KEY,
  name text
);

CREATE TABLE test.capital (
  id integer PRIMARY KEY,
  name text,
  country_id integer UNIQUE,
  FOREIGN KEY (country_id) REFERENCES test.country(id)
);

-- designers / videogames: backing tables for the computed relationships
-- (select.sql, NEW). computed_designers/computed_videogames are in section 6.
CREATE TABLE test.designers (
  id integer PRIMARY KEY,
  name text
);

CREATE TABLE test.videogames (
  id integer PRIMARY KEY,
  name text,
  designer_id integer REFERENCES test.designers(id)
);

-- tiobe_pls: text PK + rank smallint, seeded Java/C/Python (mutations superset).
CREATE TABLE test.tiobe_pls (
  name text PRIMARY KEY,
  rank smallint
);

-- single_unique / compound_unique (mutations on_conflict cases).
CREATE TABLE test.single_unique (
  unique_key integer UNIQUE NOT NULL,
  value text
);

CREATE TABLE test.compound_unique (
  key1 integer NOT NULL,
  key2 integer NOT NULL,
  value text,
  UNIQUE (key1, key2)
);

-- safe_update_items / safe_delete_items (mutations pg-safeupdate cases).
CREATE TABLE test.safe_update_items (
  id integer NOT NULL PRIMARY KEY,
  name text NOT NULL
);

CREATE TABLE test.safe_delete_items (
  id integer NOT NULL PRIMARY KEY,
  name text NOT NULL
);

-- fk_parent / fk_child: foreign_key_violation 23503 (errors.sql).
CREATE TABLE test.fk_parent (
  id int PRIMARY KEY
);

CREATE TABLE test.fk_child (
  id        int PRIMARY KEY,
  parent_id int REFERENCES test.fk_parent(id)
);

-- cv_rows: cardinality_violation source (errors.sql bad_subquery view base).
CREATE TABLE test.cv_rows (
  id int PRIMARY KEY
);

-- car_models: compound PK for multi-PK Location (headers.sql).
CREATE TABLE test.car_models (
  name text,
  year integer,
  PRIMARY KEY (name, year)
);

-- timestamps: Prefer: timezone echo (headers.sql).
CREATE TABLE test.timestamps (
  t timestamp with time zone
);

-- loc_test: blank-header regression target (headers.sql).
CREATE TABLE test.loc_test (
  id int PRIMARY KEY,
  c text
);

-- addresses + lines + ov_json (content_negotiation.sql).
CREATE TABLE test.addresses (
  id      integer PRIMARY KEY,
  address text NOT NULL
);

CREATE TABLE test.lines (
  id   int PRIMARY KEY,
  name text
);

CREATE TABLE test.ov_json ();   -- columnless, rowless; override-json aggregate

-- auto_incrementing_pk (representations.sql POST headers-only Location).
CREATE TABLE test.auto_incrementing_pk (
  id serial PRIMARY KEY,
  nullable_string character varying,
  non_nullable_string character varying NOT NULL,
  inserted_at timestamp with time zone DEFAULT now()
);

-- w_or_wo_comma_names: names containing reserved chars incl. comma
-- (url_grammar.sql, NEW — reserved-character quoting cases).
CREATE TABLE test.w_or_wo_comma_names (
  name text
);

-- managers + organizations: self-referential org tree (content_negotiation.sql).
-- Distinct from observability.organizations (different schema).
CREATE TABLE test.managers (
  id   integer PRIMARY KEY,
  name text
);

CREATE TABLE test.organizations (
  id         integer PRIMARY KEY,
  name       text,
  referee    integer REFERENCES test.organizations(id),
  auditor    integer REFERENCES test.organizations(id),
  manager_id integer REFERENCES test.managers(id)
);

-- trash / trash_details: one-to-one related ordering (ordering.sql).
CREATE TABLE test.trash (
  id int PRIMARY KEY
);

CREATE TABLE test.trash_details (
  id int PRIMARY KEY REFERENCES test.trash(id),
  jsonb_col jsonb
);

-- fav_numbers: composite-type column ordering (ordering.sql).
CREATE TABLE test.fav_numbers (
  num test.complex,
  person text
);

-- menagerie: openapi's rich type-mapping table (kept as test.menagerie).
CREATE TABLE test.menagerie(
  "integer" integer NOT NULL,
  "double" double precision NOT NULL,
  "varchar" character varying NOT NULL,
  "boolean" boolean NOT NULL,
  "date" date NOT NULL,
  "money" money NOT NULL,
  "enum" test.enum_menagerie_type NOT NULL
);

-- menagerie_empty: pagination's empty count table (RENAMED from menagerie).
CREATE TABLE test.menagerie_empty (
  "integer" integer NOT NULL PRIMARY KEY
);

-- openapi type/default detection tables (openapi.sql).
CREATE TABLE test.openapi_types(
  "a_character_varying" character varying,
  "a_character" character(1),
  "a_text" text,
  "a_boolean" boolean,
  "a_smallint" smallint,
  "a_integer" integer,
  "a_bigint" bigint,
  "a_numeric" numeric,
  "a_real" real,
  "a_double_precision" double precision,
  "a_json" json,
  "a_jsonb" jsonb,
  "a_text_arr" text[],
  "a_int_arr" int[],
  "a_bool_arr" boolean[],
  "a_char_arr" char[],
  "a_varchar_arr" varchar[],
  "a_bigint_arr" bigint[],
  "a_numeric_arr" numeric[],
  "a_json_arr" json[],
  "a_jsonb_arr" jsonb[]
);

CREATE TABLE test.openapi_defaults(
  "text" text default 'default',
  "boolean" boolean default false,
  "integer" integer default 42,
  "numeric" numeric default 42.2,
  "date" date default '1900-01-01'::date,
  "time" time default '13:00:00'::time without time zone
);

-- data-representation tables (domain_representations.sql).
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

CREATE TABLE test.evil_friends(
  id   public.devil_int,
  name text
);

-- ---------------------------- schema: private ------------------------------
CREATE TABLE private.stuff (
  id integer PRIMARY KEY,
  name text
);

-- ------------------------------ schema: v1 ---------------------------------
CREATE TABLE v1.parents (
  id   int PRIMARY KEY,
  name text
);

CREATE TABLE v1.children (
  id        int PRIMARY KEY,
  name      text,
  parent_id int,
  CONSTRAINT parent FOREIGN KEY (parent_id) REFERENCES v1.parents(id)
);

-- ------------------------------ schema: v2 ---------------------------------
CREATE TABLE v2.parents (
  id   int PRIMARY KEY,
  name text
);

CREATE TABLE v2.children (
  id        int PRIMARY KEY,
  name      text,
  parent_id int,
  CONSTRAINT parent FOREIGN KEY (parent_id) REFERENCES v2.parents(id)
);

CREATE TABLE v2.another_table (
  id            int PRIMARY KEY,
  another_value text
);

-- -------------------------- schema: تست (unicode) --------------------------
CREATE TABLE "تست"."موارد" (
  "هویت" bigint NOT NULL
);

-- ----------------------- schema: "SPECIAL ""@/\#~_-" -----------------------
CREATE TABLE "SPECIAL ""@/\#~_-".names (
  id   int PRIMARY KEY,
  name text
);

-- ------------------------- schema: observability ---------------------------
CREATE TABLE observability.organizations (
  id         integer PRIMARY KEY,
  name       text NOT NULL,
  referee    integer REFERENCES observability.organizations (id),
  auditor    integer REFERENCES observability.organizations (id),
  manager_id integer
);

CREATE TABLE observability.items (
  id serial PRIMARY KEY
);

CREATE TABLE observability.no_pk (
  a text,
  b text
);

CREATE TABLE observability.tiobe_pls (
  name text PRIMARY KEY,
  rank integer
);

CREATE TABLE observability.projects (
  id   integer PRIMARY KEY,
  name text
);

-- ===========================================================================
-- 5. Views (after their base tables)
-- ===========================================================================

-- main_jobs (select.sql) — depends on jobs/sites.
CREATE VIEW test.main_jobs AS
  SELECT * FROM test.jobs
  WHERE site_id IN (SELECT site_id FROM test.sites WHERE main_project_id IS NOT NULL);

-- stuff view over private.stuff (headers.sql); INSTEAD OF triggers in section 6.
CREATE VIEW test.stuff AS SELECT * FROM private.stuff;

-- openapi view (openapi.sql).
CREATE VIEW test.child_entities_view AS TABLE test.child_entities;

-- datarep computed view (domain_representations.sql).
CREATE VIEW test.datarep_todos_computed AS (
  SELECT id,
    name,
    label_color,
    due_at,
    (label_color / 2)::public.color AS dark_color
  FROM test.datarep_todos
);

-- bad_subquery (errors.sql) — scalar subquery returns >1 row -> 21000.
CREATE VIEW test.bad_subquery AS
  SELECT * FROM test.cv_rows WHERE id = (SELECT id FROM test.cv_rows);

-- ===========================================================================
-- 6. Functions, sequences, aggregates and triggers
-- ===========================================================================

-- ----------------------------- jwt (auth.sql) ------------------------------
CREATE OR REPLACE FUNCTION jwt.url_encode(data bytea) RETURNS text LANGUAGE sql AS $$
  SELECT translate(encode(data, 'base64'), E'+/=\n', '-_');
$$;

CREATE OR REPLACE FUNCTION jwt.algorithm_sign(signables text, secret text, algorithm text)
RETURNS text LANGUAGE sql AS $$
WITH alg AS (
  SELECT CASE
    WHEN algorithm = 'HS256' THEN 'sha256'
    WHEN algorithm = 'HS384' THEN 'sha384'
    WHEN algorithm = 'HS512' THEN 'sha512'
    ELSE '' END)
SELECT jwt.url_encode(public.hmac(signables, secret, (SELECT * FROM alg)));
$$;

CREATE OR REPLACE FUNCTION jwt.sign(payload json, secret text, algorithm text DEFAULT 'HS256')
RETURNS text LANGUAGE sql AS $$
WITH
  header AS (SELECT jwt.url_encode(convert_to('{"alg":"' || algorithm || '","typ":"JWT"}', 'utf8'))),
  payload AS (SELECT jwt.url_encode(convert_to(payload::text, 'utf8'))),
  signables AS (SELECT (SELECT * FROM header) || '.' || (SELECT * FROM payload))
SELECT (SELECT * FROM signables) || '.' ||
  jwt.algorithm_sign((SELECT * FROM signables), secret, algorithm);
$$;

-- ----------------------------- test (auth.sql) -----------------------------
CREATE OR REPLACE FUNCTION test.login(id text, pass text) RETURNS public.jwt_token
  LANGUAGE sql SECURITY DEFINER STABLE AS $$
  SELECT jwt.sign(row_to_json(r), 'reallyreallyreallyreallyverysafe') AS token
  FROM (
    SELECT rolname::text, id::text
      FROM postgrest.auth a
     WHERE a.id = login.id AND a.pass = login.pass
  ) r;
$$;

CREATE OR REPLACE FUNCTION test.jwt_test() RETURNS public.jwt_token
  LANGUAGE sql SECURITY DEFINER AS $$
  SELECT jwt.sign(row_to_json(r), 'reallyreallyreallyreallyverysafe') AS token
  FROM (
    SELECT 'joe'::text AS iss, 'fun'::text AS sub, 'everyone'::text AS aud,
           1300819380 AS exp, 1300819380 AS nbf, 1300819380 AS iat,
           'foo'::text AS jti, 'postgrest_test'::text AS role,
           true AS "http://postgrest.com/foo"
  ) r;
$$;

CREATE OR REPLACE FUNCTION test.reveal_big_jwt() RETURNS TABLE (
  iss text, sub text, exp bigint, nbf bigint, iat bigint, jti text,
  "http://postgrest.com/foo" boolean
)
LANGUAGE sql SECURITY DEFINER STABLE AS $$
  SELECT current_setting('request.jwt.claims')::json->>'iss',
         current_setting('request.jwt.claims')::json->>'sub',
         (current_setting('request.jwt.claims')::json->>'exp')::bigint,
         (current_setting('request.jwt.claims')::json->>'nbf')::bigint,
         (current_setting('request.jwt.claims')::json->>'iat')::bigint,
         current_setting('request.jwt.claims')::json->>'jti',
         (current_setting('request.jwt.claims')::json->>'http://postgrest.com/foo')::boolean;
$$;

CREATE OR REPLACE FUNCTION test.get_current_user() RETURNS text
  LANGUAGE sql STABLE AS $$ SELECT current_user::text; $$;

CREATE OR REPLACE FUNCTION test.switch_role() RETURNS void
  LANGUAGE plpgsql AS $$
declare
  user_id text;
begin
  user_id = (current_setting('request.jwt.claims')::json->>'id')::text;
  if user_id = '1'::text then
    execute 'set local role postgrest_test_author';
  elseif user_id = '2'::text then
    execute 'set local role postgrest_test_default_role';
  elseif user_id = '3'::text then
    raise exception 'Disabled ID --> %', user_id using hint = 'Please contact administrator';
  end if;
end
$$;

CREATE OR REPLACE FUNCTION test.privileged_hello(name text) RETURNS text
  LANGUAGE sql AS $$ SELECT 'Privileged hello to ' || $1; $$;

CREATE OR REPLACE FUNCTION test.get_guc_value(name text) RETURNS text
  LANGUAGE sql AS $$ SELECT nullif(current_setting(name), '')::text; $$;

CREATE OR REPLACE FUNCTION test.get_guc_value(prefix text, name text) RETURNS text
  LANGUAGE sql AS $$ SELECT nullif(current_setting(prefix)::json->>name, '')::text; $$;

-- ---------------------------- test (headers.sql) ---------------------------
CREATE OR REPLACE FUNCTION test.location_for_stuff() RETURNS trigger AS $$
begin
    insert into private.stuff values (new.id, new.name);
    if new.id is not null then
      perform set_config(
        'response.headers',
        format('[{"Location": "/%s?id=eq.%s&overriden=true"}]', tg_table_name, new.id),
        true
      );
    end if;
    return new;
end
$$ LANGUAGE plpgsql SECURITY DEFINER;
CREATE TRIGGER location_for_stuff INSTEAD OF INSERT ON test.stuff
  FOR EACH ROW EXECUTE PROCEDURE test.location_for_stuff();

CREATE OR REPLACE FUNCTION test.status_205_for_updated_stuff() RETURNS trigger AS $$
begin
    update private.stuff set id = new.id, name = new.name;
    perform set_config('response.status', '205', true);
    return new;
end
$$ LANGUAGE plpgsql SECURITY DEFINER;
CREATE TRIGGER status_205_for_updated_stuff INSTEAD OF UPDATE ON test.stuff
  FOR EACH ROW EXECUTE PROCEDURE test.status_205_for_updated_stuff();

CREATE OR REPLACE FUNCTION test.get_projects_and_guc_headers() RETURNS SETOF test.projects AS $$
  set local "response.headers" = '[{"X-Test": "key1=val1; someValue; key2=val2"}, {"X-Test-2": "key1=val1"}]';
  select * from test.projects;
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION test.get_int_and_guc_headers(num int) RETURNS integer AS $$
  set local "response.headers" = '[{"X-Test":"key1=val1; someValue; key2=val2"},{"X-Test-2":"key1=val1"}]';
  select num;
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION test.bad_guc_headers_1() RETURNS void AS $$
  set local "response.headers" = '{"X-Test": "invalid structure for headers"}';
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION test.set_cookie_twice() RETURNS void AS $$
  set local "response.headers" = '[{"Set-Cookie": "sessionid=38afes7a8; HttpOnly; Path=/"}, {"Set-Cookie": "id=a3fWa; Expires=Wed, 21 Oct 2015 07:28:00 GMT; Secure; HttpOnly"}]';
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION test.send_body_status_403() RETURNS json AS $$
begin
  perform set_config('response.status', '403', true);
  return json_build_object('message', 'invalid user or password');
end;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION test.send_bad_status() RETURNS json AS $$
begin
  perform set_config('response.status', 'bad', true);
  return null;
end;
$$ LANGUAGE plpgsql;

-- ----------------------- test (content_negotiation.sql) --------------------
-- getproject / getallprojects are consolidated below (shared with rpc.sql).
CREATE OR REPLACE FUNCTION test.unnamed_bytea_param(bytea) RETURNS bytea AS $$
  SELECT $1;
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION test.get_lines() RETURNS SETOF test.lines AS $$
  SELECT * FROM test.lines;
$$ LANGUAGE sql STABLE;

-- anyelement aggregate handler for application/vnd.geo2+json.
CREATE OR REPLACE FUNCTION test.geo2json_trans(state public."application/vnd.geo2+json", next anyelement)
RETURNS public."application/vnd.geo2+json" AS $$
  SELECT (state || to_jsonb(next))::public."application/vnd.geo2+json";
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION test.geo2json_final(data public."application/vnd.geo2+json")
RETURNS public."application/vnd.geo2+json" AS $$
  SELECT (jsonb_build_object('type', 'FeatureCollection', 'hello', 'world'))::public."application/vnd.geo2+json";
$$ LANGUAGE sql;

CREATE AGGREGATE test.geo2json_agg_any(anyelement) (
  initcond  = '[]',
  stype     = public."application/vnd.geo2+json",
  sfunc     = test.geo2json_trans,
  finalfunc = test.geo2json_final
);

-- override the builtin application/json handler for the ov_json table.
CREATE OR REPLACE FUNCTION test.ov_json_trans(state public."application/json", next test.ov_json)
RETURNS public."application/json" AS $$
  SELECT NULL::public."application/json";
$$ LANGUAGE sql;

CREATE AGGREGATE test.ov_json_agg(test.ov_json) (
  initcond = '{"overridden": "true"}',
  stype    = public."application/json",
  sfunc    = test.ov_json_trans
);

-- the Any ("*/*") handler defaulting to application/octet-stream.
CREATE OR REPLACE FUNCTION test.ret_any_mt()
RETURNS public."*/*" AS $$
  SELECT 'any'::public."*/*";
$$ LANGUAGE sql;

-- ------------------------------ test (rpc.sql) -----------------------------
CREATE FUNCTION test.add_them(a integer, b integer) RETURNS integer
  LANGUAGE sql IMMUTABLE
  AS $$ SELECT a + b; $$;

CREATE FUNCTION test.sayhello(name text) RETURNS text
  LANGUAGE sql IMMUTABLE
  AS $$ SELECT 'Hello, ' || name; $$;

CREATE FUNCTION test.noparamsproc() RETURNS text
  LANGUAGE sql IMMUTABLE
  AS $$ SELECT a FROM (VALUES ('Return value of no parameters procedure.')) s(a); $$;

CREATE FUNCTION test.ret_setof_integers() RETURNS SETOF integer
  LANGUAGE sql IMMUTABLE
  AS $$ VALUES (1), (2), (3); $$;

CREATE FUNCTION test.ret_array() RETURNS integer[]
  LANGUAGE sql IMMUTABLE
  AS $$ SELECT '{1,2,3}'::integer[]; $$;

CREATE FUNCTION test.test_empty_rowset() RETURNS SETOF integer
  LANGUAGE sql IMMUTABLE
  AS $$ SELECT null::int FROM (SELECT 1) a WHERE false; $$;

CREATE FUNCTION test.ret_void() RETURNS void LANGUAGE sql AS '';

CREATE FUNCTION test.ret_point_2d() RETURNS test.point_2d
  LANGUAGE sql IMMUTABLE
  AS $$ SELECT row(10, 5)::test.point_2d; $$;

CREATE FUNCTION test.single_out_param(num int, OUT num_plus_one int)
  LANGUAGE sql IMMUTABLE
  AS $$ SELECT num + 1; $$;

CREATE FUNCTION test.single_inout_param(INOUT num int)
  LANGUAGE sql IMMUTABLE
  AS $$ SELECT num + 1; $$;

CREATE FUNCTION test.many_out_params(OUT my_json json, OUT num int, OUT str text)
  LANGUAGE sql IMMUTABLE
  AS $$ SELECT '{"a": 1, "b": "two"}'::json, 3, 'four'::text; $$;

CREATE FUNCTION test.single_column_table_return() RETURNS TABLE (a text)
  LANGUAGE sql IMMUTABLE
  AS $$ SELECT 'A'::text; $$;

CREATE FUNCTION test.multi_column_table_return() RETURNS TABLE (a text, b text)
  LANGUAGE sql IMMUTABLE
  AS $$ SELECT 'A'::text, 'B'::text; $$;

CREATE FUNCTION test.variadic_param(VARIADIC v text[] DEFAULT '{}')
  RETURNS text[]
  LANGUAGE sql IMMUTABLE
  AS $$ SELECT v; $$;

CREATE FUNCTION test.three_defaults(a int DEFAULT 1, b int DEFAULT 2, c int DEFAULT 3)
  RETURNS int
  LANGUAGE sql IMMUTABLE
  AS $$ SELECT a + b + c; $$;

CREATE SEQUENCE test.callcounter_count START 1;
CREATE FUNCTION test.callcounter() RETURNS bigint
  LANGUAGE sql VOLATILE
  AS $$ SELECT nextval('test.callcounter_count'); $$;

-- Overloaded functions (NEW): same name, distinct signatures.
CREATE FUNCTION test.overloaded() RETURNS SETOF int
  LANGUAGE sql IMMUTABLE
  AS $$ VALUES (1), (2), (3); $$;

CREATE FUNCTION test.overloaded(a int, b int) RETURNS int
  LANGUAGE sql IMMUTABLE
  AS $$ SELECT a + b; $$;

CREATE FUNCTION test.overloaded(a text, b text, c text) RETURNS text
  LANGUAGE sql IMMUTABLE
  AS $$ SELECT a || b || c; $$;

-- Single unnamed vs named json parameter (NEW).
CREATE FUNCTION test.unnamed_json_param(json) RETURNS json
  LANGUAGE sql IMMUTABLE
  AS $$ SELECT $1; $$;

CREATE FUNCTION test.named_json_param(data json) RETURNS json
  LANGUAGE sql IMMUTABLE
  AS $$ SELECT data; $$;

-- RAISE PT402 (also defined identically in errors.sql; one definition kept).
CREATE OR REPLACE FUNCTION test.raise_pt402() RETURNS void
  LANGUAGE plpgsql
  AS $$
  BEGIN
    RAISE sqlstate 'PT402' USING message = 'Payment Required',
                                 detail = 'Quota exceeded',
                                 hint = 'Upgrade your plan';
  END;
  $$;

-- Consolidated SETOF helpers shared across rpc/pagination/content_negotiation.
-- getitemrange: identical in rpc.sql + pagination.sql.
CREATE FUNCTION test.getitemrange(min bigint, max bigint) RETURNS SETOF test.items
  LANGUAGE sql STABLE
  AS $$ SELECT * FROM test.items WHERE id > min AND id <= max; $$;

-- getproject: STABLE so the rpc GET case (1422) works; shared with content_neg.
CREATE FUNCTION test.getproject(id int) RETURNS SETOF test.projects
  LANGUAGE sql STABLE
  AS $$ SELECT * FROM test.projects WHERE id = $1; $$;

-- getallprojects: STABLE (GET-callable) AND ROWS 2019 (pagination count=planned).
CREATE FUNCTION test.getallprojects() RETURNS SETOF test.projects
  LANGUAGE sql STABLE ROWS 2019
  AS $$ SELECT * FROM test.projects; $$;

-- get_projects_above: ROWS 1 estimate (pagination count=planned).
CREATE FUNCTION test.get_projects_above(id int) RETURNS SETOF test.projects
  LANGUAGE sql ROWS 1
  AS $$ SELECT * FROM test.projects WHERE id > $1; $$;

-- computed relationships over videogames/designers (select.sql, NEW).
CREATE FUNCTION test.computed_designers(test.videogames) RETURNS SETOF test.designers
  LANGUAGE sql STABLE ROWS 1
  AS $$ SELECT * FROM test.designers WHERE id = $1.designer_id $$;

CREATE FUNCTION test.computed_videogames(test.designers) RETURNS SETOF test.videogames
  LANGUAGE sql STABLE
  AS $$ SELECT * FROM test.videogames WHERE designer_id = $1.id $$;

-- ----------------------------- test (errors.sql) ---------------------------
-- (raise_pt402 already defined above with rpc.sql; rest follow.)
CREATE OR REPLACE FUNCTION test.raise_bad_pt() RETURNS void AS $$
begin
  raise sqlstate 'PT40A' using message = 'Wrong';
end;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION test.raise_sqlstate_test1() RETURNS void
  LANGUAGE plpgsql AS $$
begin
  raise sqlstate 'PGRST' using
    message = '{"code":"123","message":"ABC","details":"DEF","hint":"XYZ"}',
    detail  = '{"status":332,"status_text":"My Custom Status","headers":{"X-Header":"str"}}';
end
$$;

CREATE OR REPLACE FUNCTION test.raise_sqlstate_test2() RETURNS void
  LANGUAGE plpgsql AS $$
begin
  raise sqlstate 'PGRST' using
    message = '{"code":"123","message":"ABC"}',
    detail  = '{"status":332,"headers":{"X-Header":"str"}}';
end
$$;

CREATE OR REPLACE FUNCTION test.raise_sqlstate_test3() RETURNS void
  LANGUAGE plpgsql AS $$
begin
  raise sqlstate 'PGRST' using
    message = '{"code":"123","message":"ABC"}',
    detail  = '{"status":404,"headers":{"X-Header":"str"}}';
end
$$;

CREATE OR REPLACE FUNCTION test.raise_sqlstate_test4() RETURNS void
  LANGUAGE plpgsql AS $$
begin
  raise sqlstate 'PGRST' using
    message = '{"code":"123","message":"ABC"}',
    detail  = '{"status":404,"status_text":"My Not Found","headers":{"X-Header":"str"}}';
end
$$;

CREATE OR REPLACE FUNCTION test.raise_sqlstate_invalid_json_message() RETURNS void
  LANGUAGE plpgsql AS $$
begin
  raise sqlstate 'PGRST' using
    message = 'INVALID',
    detail  = '{"status":332,"headers":{"X-Header":"str"}}';
end
$$;

CREATE OR REPLACE FUNCTION test.raise_sqlstate_invalid_json_details() RETURNS void
  LANGUAGE plpgsql AS $$
begin
  raise sqlstate 'PGRST' using
    message = '{"code":"123","message":"ABC","details":"DEF"}',
    detail  = 'INVALID';
end
$$;

CREATE OR REPLACE FUNCTION test.raise_sqlstate_missing_details() RETURNS void
  LANGUAGE plpgsql AS $$
begin
  raise sqlstate 'PGRST' using
    message = '{"code":"123","message":"ABC","details":"DEF"}';
end
$$;

CREATE OR REPLACE FUNCTION test.problem() RETURNS void
  LANGUAGE plpgsql AS $$
begin
  raise 'bad thing';
end;
$$;

CREATE OR REPLACE FUNCTION test.assert() RETURNS void
  LANGUAGE plpgsql AS $$
begin
  assert false, 'bad thing';
end;
$$;

-- --------------------------- test (ordering.sql) ---------------------------
CREATE FUNCTION test.anti_id(test.items) RETURNS bigint
  LANGUAGE sql IMMUTABLE
  AS $_$ SELECT $1.id * -1 $_$;

-- always_true(test.items): defined identically in ordering.sql AND select.sql.
CREATE FUNCTION test.always_true(test.items) RETURNS boolean
  LANGUAGE sql IMMUTABLE
  AS $$ SELECT true $$;

-- ---------------------------- test (openapi.sql) ---------------------------
CREATE FUNCTION test.varied_arguments_openapi(
  double double precision,
  "varchar" character varying,
  "boolean" boolean,
  date date,
  money money,
  enum test.enum_menagerie_type,
  text_arr text[],
  int_arr int[],
  bool_arr boolean[],
  char_arr char[],
  varchar_arr varchar[],
  bigint_arr bigint[],
  numeric_arr numeric[],
  json_arr json[],
  jsonb_arr jsonb[],
  "integer" integer default 42,
  "json" json default '{}',
  jsonb jsonb default '{}'
) RETURNS json
  LANGUAGE sql
  IMMUTABLE
AS $_$
  SELECT json_build_object('double', double, 'integer', "integer");
$_$;

CREATE FUNCTION test.reset_table() RETURNS void
  LANGUAGE sql
  VOLATILE
AS $$ SELECT 1; $$;

CREATE FUNCTION test.getallusers() RETURNS setof test.entities
  LANGUAGE sql
  STABLE
AS $$ SELECT * FROM test.entities; $$;

CREATE FUNCTION test.root() RETURNS json
  LANGUAGE sql
AS $_$
  SELECT $$
    {
      "swagger": "2.0",
      "info": {
        "title": "Overridden",
        "description": "This is a my own API"
      }
    }
  $$::json;
$_$;

-- --------------------------------- v1 / v2 ---------------------------------
CREATE FUNCTION v1.get_parents_below(id int)
RETURNS setof v1.parents AS $$
  SELECT * FROM v1.parents WHERE id < $1;
$$ LANGUAGE sql;

CREATE FUNCTION v2.get_parents_below(id int)
RETURNS setof v2.parents AS $$
  SELECT * FROM v2.parents WHERE id < $1;
$$ LANGUAGE sql;

-- ------------------------------ observability ------------------------------
CREATE FUNCTION observability.ret_point_overloaded(x integer, y integer) RETURNS observability.point_2d AS $$
  SELECT row(x, y)::observability.point_2d;
$$ LANGUAGE sql;

CREATE FUNCTION observability.add_them(a integer, b integer) RETURNS integer AS $$
  SELECT a + b;
$$ LANGUAGE sql;

CREATE FUNCTION observability.getallprojects() RETURNS SETOF observability.projects AS $$
  SELECT * FROM observability.projects;
$$ LANGUAGE sql;

CREATE FUNCTION observability.sleep(seconds double precision) RETURNS void AS $$
  SELECT pg_sleep(seconds);
$$ LANGUAGE sql;

-- ===========================================================================
-- 6b. Views that depend on functions (after the functions exist)
-- ===========================================================================
CREATE VIEW test.getallprojects_view AS
  SELECT * FROM test.getallprojects();

CREATE VIEW test.get_projects_above_view AS
  SELECT * FROM test.get_projects_above(1);

-- ===========================================================================
-- 7. COMMENTs (openapi.sql) — after the objects they describe
-- ===========================================================================
COMMENT ON SCHEMA test IS
$$My API title

My API description
that spans
multiple lines$$;

COMMENT ON TABLE test.child_entities IS 'child_entities comment';
COMMENT ON COLUMN test.child_entities.id IS 'child_entities id comment';
COMMENT ON COLUMN test.child_entities.name IS 'child_entities name comment. Can be longer than sixty-three characters long';

COMMENT ON VIEW test.child_entities_view IS 'child_entities_view comment';
COMMENT ON COLUMN test.child_entities_view.id IS 'child_entities_view id comment';
COMMENT ON COLUMN test.child_entities_view.name IS 'child_entities_view name comment. Can be longer than sixty-three characters long';

COMMENT ON TABLE test.grandchild_entities IS
$$grandchild_entities summary

grandchild_entities description
that spans
multiple lines$$;

COMMENT ON FUNCTION test.varied_arguments_openapi(double precision, character varying, boolean, date, money, test.enum_menagerie_type, text[], int[], boolean[], char[], varchar[], bigint[], numeric[], json[], jsonb[], integer, json, jsonb) IS
  $_$An RPC function

Just a test for RPC function arguments$_$;

-- ===========================================================================
-- 8. Data (after all tables/sequences/functions exist)
-- ===========================================================================

-- postgrest.auth
INSERT INTO postgrest.auth (id, rolname, pass) VALUES ('jdoe', 'postgrest_test_author', '1234');

-- test.items 1..15
INSERT INTO test.items (id) SELECT generate_series(1, 15);
SELECT pg_catalog.setval('test.items_id_seq', 15, true);

-- test.simple_pk
INSERT INTO test.simple_pk (k, extra) VALUES ('xyyx', 'u'), ('xYYx', 'v');

-- test.no_pk
INSERT INTO test.no_pk (a, b) VALUES (NULL, NULL), ('1', '0'), ('2', '0');

-- test.nullable_integer
INSERT INTO test.nullable_integer (a) VALUES (NULL);

-- test.only_pk
INSERT INTO test.only_pk (id) VALUES (1), (2);

-- test.articles (operators seed; owner explicit so default is irrelevant)
INSERT INTO test.articles (id, body, owner) VALUES
  (1, 'No… It''s a thing; it''s like a plan, but with more greatness.', 'diogo'),
  (2, 'Stop talking, brain thinking. Hush.', 'diogo'),
  (3, 'It''s a fez. I wear a fez now. Fezes are cool.', 'diogo');

-- test.complex_items (mutations seed; arr_data populated)
INSERT INTO test.complex_items (id, name, settings, arr_data) VALUES
  (1, 'One',   '{"foo":{"int":1,"bar":"baz"}}', '{1,2,3}'),
  (2, 'Two',   '{"foo":{"int":1,"bar":"baz"}}', '{1,2,3}'),
  (3, 'Three', '{"foo":{"int":1,"bar":"baz"}}', '{1,2,3}');

-- test.json_arr (filters' 10-row superset)
INSERT INTO test.json_arr VALUES (1, '[1, 2, 3]');
INSERT INTO test.json_arr VALUES (2, '[4, 5, 6]');
INSERT INTO test.json_arr VALUES (3, '[[9, 8, 7], [11, 12, 13]]');
INSERT INTO test.json_arr VALUES (4, '[[[5, 6], 7, 8]]');
INSERT INTO test.json_arr VALUES (5, '[{"a": "A"}, {"b": "B"}]');
INSERT INTO test.json_arr VALUES (6, '[{"a": [1,2,3]}, {"b": [4,5]}]');
INSERT INTO test.json_arr VALUES (7, '{"c": [1,2,3], "d": [4,5]}');
INSERT INTO test.json_arr VALUES (8, '{"c": [{"d": [4,5,6,7,8]}]}');
INSERT INTO test.json_arr VALUES (9, '[{"0xy1": [1,{"23-xy-45": [2, {"xy-6": [3]}]}]}]');
INSERT INTO test.json_arr VALUES (10, '{"!@#$%^&*_a": [{"!@#$%^&*_b": 1}, {"!@#$%^&*_c": [2]}], "!@#$%^&*_d": {"!@#$%^&*_e": 3}}');

-- test.json_table
INSERT INTO test.json_table VALUES ('{"foo":{"bar":"baz"},"id":1}');
INSERT INTO test.json_table VALUES ('{"id":3}');
INSERT INTO test.json_table VALUES ('{"id":0}');

-- test.jsonb_test
INSERT INTO test.jsonb_test VALUES (1, '{ "a": {"b": 2} }');
INSERT INTO test.jsonb_test VALUES (2, '{ "c": [1,2,3] }');
INSERT INTO test.jsonb_test VALUES (3, '[{ "d": "test" }]');
INSERT INTO test.jsonb_test VALUES (4, '{ "e": 1 }');

-- test.ranges
INSERT INTO test.ranges VALUES (1, '[1,3]'), (2, '[3,6]'), (3, '[6,9]'), (4, '[9,12]'), (5, null);

-- test.chores
INSERT INTO test.chores (id, name, done) VALUES
  (1, 'take out the garbage', true),
  (2, 'do the laundry', false),
  (3, 'wash the dishes', null);

-- test.tsearch
INSERT INTO test.tsearch VALUES (to_tsvector('It''s kind of fun to do the impossible'));
INSERT INTO test.tsearch VALUES (to_tsvector('But also fun to do what is possible'));
INSERT INTO test.tsearch VALUES (to_tsvector('Fat cats ate rats'));
INSERT INTO test.tsearch VALUES (to_tsvector('french', 'C''est un peu amusant de faire l''impossible'));
INSERT INTO test.tsearch VALUES (to_tsvector('german', 'Es ist eine Art Spaß, das Unmögliche zu machen'));

-- test.entities / child_entities / grandchild_entities (filters seed w/ tsvector)
INSERT INTO test.entities VALUES (1, 'entity 1', '{1}', '''bar'':2 ''foo'':1');
INSERT INTO test.entities VALUES (2, 'entity 2', '{1,2}', '''baz'':1 ''qux'':2');
INSERT INTO test.entities VALUES (3, 'entity 3', '{1,2,3}', null);
INSERT INTO test.entities VALUES (4, null, null, null);

INSERT INTO test.child_entities VALUES (1, 'child entity 1', 1);
INSERT INTO test.child_entities VALUES (2, 'child entity 2', 1);
INSERT INTO test.child_entities VALUES (3, 'child entity 3', 2);
INSERT INTO test.child_entities VALUES (4, 'child entity 4', 1);
INSERT INTO test.child_entities VALUES (5, 'child entity 5', 1);
INSERT INTO test.child_entities VALUES (6, 'child entity 6', 2);

INSERT INTO test.grandchild_entities VALUES (1, 'grandchild entity 1', 1, null, null, null);
INSERT INTO test.grandchild_entities VALUES (2, 'grandchild entity 2', 1, null, null, null);
INSERT INTO test.grandchild_entities VALUES (3, 'grandchild entity 3', 2, null, null, null);
INSERT INTO test.grandchild_entities VALUES (4, '(grandchild,entity,4)', 2, null, null, '{"a": {"b":"foo"}}');
INSERT INTO test.grandchild_entities VALUES (5, '(grandchild,entity,5)', 2, null, null, '{"b":"bar"}');

-- test.clients / projects (5 rows incl. Orphan)
INSERT INTO test.clients VALUES (1, 'Microsoft'), (2, 'Apple');
INSERT INTO test.projects VALUES (1, 'Windows 7', 1);
INSERT INTO test.projects VALUES (2, 'Windows 10', 1);
INSERT INTO test.projects VALUES (3, 'IOS', 2);
INSERT INTO test.projects VALUES (4, 'OSX', 2);
INSERT INTO test.projects VALUES (5, 'Orphan', NULL);

-- test.tasks
INSERT INTO test.tasks VALUES (1, 'Design w7', 1);
INSERT INTO test.tasks VALUES (2, 'Code w7', 1);
INSERT INTO test.tasks VALUES (3, 'Design w10', 2);
INSERT INTO test.tasks VALUES (4, 'Code w10', 2);
INSERT INTO test.tasks VALUES (5, 'Design IOS', 3);
INSERT INTO test.tasks VALUES (6, 'Code IOS', 3);
INSERT INTO test.tasks VALUES (7, 'Design OSX', 4);
INSERT INTO test.tasks VALUES (8, 'Code OSX', 4);

-- test.users
INSERT INTO test.users VALUES (1, 'Angela Martin');
INSERT INTO test.users VALUES (2, 'Michael Scott');
INSERT INTO test.users VALUES (3, 'Dwight Schrute');

-- test.users_tasks
INSERT INTO test.users_tasks VALUES (1, 1);
INSERT INTO test.users_tasks VALUES (1, 2);
INSERT INTO test.users_tasks VALUES (1, 3);
INSERT INTO test.users_tasks VALUES (1, 4);
INSERT INTO test.users_tasks VALUES (2, 5);
INSERT INTO test.users_tasks VALUES (2, 6);
INSERT INTO test.users_tasks VALUES (2, 7);
INSERT INTO test.users_tasks VALUES (3, 1);
INSERT INTO test.users_tasks VALUES (3, 5);

-- test.project_invoices
INSERT INTO test.project_invoices VALUES (1, 100,  1);
INSERT INTO test.project_invoices VALUES (2, 200,  1);
INSERT INTO test.project_invoices VALUES (3, 500,  2);
INSERT INTO test.project_invoices VALUES (4, 700,  2);
INSERT INTO test.project_invoices VALUES (5, 1200, 3);
INSERT INTO test.project_invoices VALUES (6, 2000, 3);
INSERT INTO test.project_invoices VALUES (7, 100,  4);
INSERT INTO test.project_invoices VALUES (8, 4000, 4);

-- test.students / students_info (NEW)
INSERT INTO test.students (id, code, name) VALUES (1, '0001', 'John Doe'), (2, '0002', 'Jane Doe');
INSERT INTO test.students_info (id, code, address) VALUES (1, '0001', 'Street 1'), (2, '0002', 'Street 2');

-- test.country / capital (NEW)
INSERT INTO test.country (id, name) VALUES (1, 'Afghanistan'), (2, 'Algeria');
INSERT INTO test.capital (id, name, country_id) VALUES (1, 'Kabul', 1), (2, 'Algiers', 2);

-- test.designers / videogames (NEW)
INSERT INTO test.designers (id, name) VALUES (1, 'Sid Meier'), (2, 'Hironobu Sakaguchi');
INSERT INTO test.videogames (id, name, designer_id) VALUES
  (1, 'Civilization I',  1),
  (2, 'Civilization II', 1),
  (3, 'Final Fantasy I',  2),
  (4, 'Final Fantasy II', 2);

-- test.tiobe_pls (mutations seed: Java/C/Python)
INSERT INTO test.tiobe_pls (name, rank) VALUES ('Java', 1), ('C', 2), ('Python', 4);

-- test.single_unique / compound_unique
INSERT INTO test.single_unique (unique_key, value) VALUES (1, 'A');
INSERT INTO test.compound_unique (key1, key2, value) VALUES (1, 1, 'A');

-- test.safe_update_items / safe_delete_items
INSERT INTO test.safe_update_items (id, name) VALUES (1, 'item-1'), (2, 'item-2');
INSERT INTO test.safe_delete_items (id, name) VALUES (1, 'item-1'), (2, 'item-2');

-- test.cv_rows (cardinality_violation)
INSERT INTO test.cv_rows VALUES (1), (2);

-- test.timestamps
INSERT INTO test.timestamps VALUES
  ('2023-10-18 12:37:59.611000+0000'),
  ('2023-10-18 14:37:59.611000+0000'),
  ('2023-10-18 16:37:59.611000+0000');

-- test.addresses
INSERT INTO test.addresses (id, address) VALUES
  (1, 'address 1'), (2, 'address 2'), (3, 'address 3'), (4, 'address 4');

-- test.lines
INSERT INTO test.lines (id, name) VALUES (1, 'line-1'), (2, 'line-2');

-- test.w_or_wo_comma_names (NEW)
INSERT INTO test.w_or_wo_comma_names (name) VALUES
  ('Hebdon, John'),
  ('Williams, Mary'),
  ('Smith, Joseph'),
  ('David White'),
  ('Larry Thompson'),
  ('Double O Seven(007)');

-- test.managers / organizations
INSERT INTO test.managers (id, name) VALUES
  (1, 'Referee Manager'), (2, 'Auditor Manager'), (3, 'Acme Manager'),
  (4, 'Umbrella Manager'), (5, 'Cyberdyne Manager'), (6, 'Oscorp Manager');
INSERT INTO test.organizations (id, name, referee, auditor, manager_id) VALUES
  (1, 'Referee Org', NULL, NULL, 1),
  (2, 'Auditor Org', NULL, NULL, 2),
  (3, 'Acme',        1,    2,    3),
  (4, 'Umbrella',    1,    2,    4),
  (5, 'Cyberdyne',   3,    4,    5),
  (6, 'Oscorp',      3,    4,    6);

-- test.trash / trash_details
INSERT INTO test.trash(id) VALUES (1), (2), (3);
INSERT INTO test.trash_details(id, jsonb_col) VALUES (1, '{"key": 10}'), (2, '{"key": 6}'), (3, '{"key": 8}');

-- test.fav_numbers
INSERT INTO test.fav_numbers VALUES (ROW(0.5, 0.5), 'A'), (ROW(0.6, 0.6), 'B');

-- data-representation seed (domain_representations.sql)
INSERT INTO test.datarep_todos VALUES (1, 'Report', 0, '2018-01-02', '\x89504e470d0a1a0a0000000d4948445200000001000000010100000000376ef924000000001049444154789c62600100000000ffff03000000060005057bfabd400000000049454e44ae426082', '2017-12-14 01:02:30', 12.50);
INSERT INTO test.datarep_todos VALUES (2, 'Essay', 256, '2018-01-03', NULL, '2017-12-14 01:02:30', 100000000000000.13);
INSERT INTO test.datarep_todos VALUES (3, 'Algebra', 123456, '2018-01-01 14:12:34.123456');
INSERT INTO test.datarep_todos VALUES (4, 'Opus Magnum', NULL, NULL);

INSERT INTO test.datarep_next_two_todos VALUES (1, 2, 3, 'school related');
INSERT INTO test.datarep_next_two_todos VALUES (2, 1, 3, 'do these first');
-- evil_friends intentionally has NO seed rows.

-- private.stuff
INSERT INTO private.stuff (id, name) VALUES (1, 'stuff 1');

-- v1 / v2 (url_grammar seed)
INSERT INTO v1.parents (id, name) VALUES (1, 'parent v1-1'), (2, 'parent v1-2');
INSERT INTO v1.children (id, name, parent_id) VALUES (1, 'child v1-1', 1), (2, 'child v1-2', 2);
INSERT INTO v2.parents (id, name) VALUES (3, 'parent v2-3'), (4, 'parent v2-4');
INSERT INTO v2.children (id, name, parent_id) VALUES (1, 'child v2-3', 3);
INSERT INTO v2.another_table (id, another_value) VALUES (5, 'value 5'), (6, 'value 6');

-- "SPECIAL ""@/\#~_-".names
INSERT INTO "SPECIAL ""@/\#~_-".names (id, name) VALUES (1, 'John'), (2, 'Mary'), (3, 'José');

-- observability
INSERT INTO observability.organizations (id, name, referee, auditor, manager_id) VALUES
  (1, 'Referee Org', NULL, NULL, NULL),
  (2, 'Auditor Org', NULL, NULL, NULL),
  (3, 'Acme',        NULL, NULL, NULL),
  (4, 'Umbrella',    NULL, NULL, NULL),
  (6, 'Oscorp',      3,    4,    6);
INSERT INTO observability.items (id) SELECT generate_series(1, 5);
INSERT INTO observability.no_pk (a, b) VALUES ('1', '0');
INSERT INTO observability.tiobe_pls (name, rank) VALUES ('Python', 1);
INSERT INTO observability.projects (id, name) VALUES (1, 'Windows 7'), (2, 'Windows 10'), (3, 'IOS');

-- ===========================================================================
-- 9. Privileges (auth.sql + openapi.sql)
-- ===========================================================================
GRANT USAGE ON SCHEMA test, public, jwt, postgrest TO postgrest_test_anonymous;
GRANT USAGE ON SCHEMA test TO postgrest_test_author;
GRANT USAGE ON SCHEMA test TO postgrest_test_default_role;

-- anonymous reads (auth.sql / config.sql)
GRANT SELECT ON TABLE test.items TO postgrest_test_anonymous;
GRANT SELECT, INSERT ON TABLE test.has_count_column TO postgrest_test_anonymous;

-- openapi.sql: anon may CRUD the documented tables (NOT authors_only).
GRANT SELECT, INSERT, UPDATE, DELETE ON
  test.entities, test.child_entities, test.child_entities_view,
  test.grandchild_entities, test.openapi_types, test.openapi_defaults,
  test.menagerie
  TO postgrest_test_anonymous, postgrest_test_author;

GRANT EXECUTE ON FUNCTION
  test.varied_arguments_openapi(double precision, character varying, boolean, date, money, test.enum_menagerie_type, text[], int[], boolean[], char[], varchar[], bigint[], numeric[], json[], jsonb[], integer, json, jsonb),
  test.reset_table(), test.getallusers(), test.root()
  TO postgrest_test_anonymous, postgrest_test_author;

-- author: owns/guards authors_only + privileged_hello.
GRANT ALL ON TABLE test.authors_only TO postgrest_test_author;
REVOKE EXECUTE ON FUNCTION test.privileged_hello(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION test.privileged_hello(text) TO postgrest_test_author;

COMMIT;

-- ============================================================================
-- VERIFICATION
-- ============================================================================
-- Verified to load into a fresh scratch database via `psql -v ON_ERROR_STOP=1
-- -f` (single transaction, zero errors), then dropped. The local server is
-- PostgreSQL 18; all DDL used here is standard SQL available unchanged in
-- PostgreSQL 14/15/16 (custom-media DOMAINs + AGGREGATEs, CREATE CAST, COMMENT
-- ON, INSTEAD OF triggers, ROWS estimates, CHECK domains, overloaded functions
-- — all predate PG14), so it loads identically on those versions. The only
-- planner-dependent behavior is the ROWS estimate on getallprojects()/
-- get_projects_above() consumed by count=planned cases, which is intentional
-- and unchanged across PG14-18.
-- ============================================================================
