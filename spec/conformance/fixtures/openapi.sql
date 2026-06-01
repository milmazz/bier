-- Fixtures for the "openapi" feature area.
-- Covers: OpenAPI 3.0 (Swagger 2.0) document generation, descriptions sourced
-- from COMMENTs (schema/title, table summary/description, column descriptions,
-- PK/FK <pk/>/<fk/> annotations), PostgreSQL->Swagger type mapping, default
-- value detection, RPC path items (GET/POST per volatility), and security
-- schemes (JWT apiKey) gated by openapi-security-active.
--
-- Derived from PostgREST v14.12 test/spec/fixtures/schema.sql.
-- Tables/functions are a minimal self-contained subset sufficient for the
-- cases in spec/conformance/cases/16xx_*.yaml.
--
-- Source anchors (v14.12 test/spec/fixtures/schema.sql):
--   schema "test" comment (title/description):   schema.sql#L20
--   entities / child_entities / view:            schema.sql#L1167 / #L1174 / #L1180
--   grandchild_entities (multi-line comment):    schema.sql#L1182 / #L1209
--   table+column+view comments:                  schema.sql#L1201 .. #L1214
--   openapi_types:                               schema.sql#L1829
--   openapi_defaults:                            schema.sql#L1853
--   enum_menagerie_type / menagerie.enum:        (enum type used by varied_arguments_openapi)
--   varied_arguments_openapi function + comment:  schema.sql#L285 / #L330
--   authors_only (privileged table):             test/spec/fixtures/privileges.sql
--   privileged_hello (privileged function):      test/spec/fixtures/privileges.sql

CREATE SCHEMA IF NOT EXISTS test;
SET search_path = test, public;

-- The schema comment becomes the OpenAPI info.title (first line) and
-- info.description (remaining lines after stripping leading newlines).
-- Source: src/PostgREST/Response/OpenAPI.hs#L416 (dTitle/dDesc breakOn "\n")
COMMENT ON SCHEMA test IS
$$My API title

My API description
that spans
multiple lines$$;

-- ---------------------------------------------------------------------------
-- Entities / child_entities: table + view + FK, with COMMENTs
-- ---------------------------------------------------------------------------

CREATE TABLE test.entities (
  id integer primary key,
  name text,
  arr integer[]
);

CREATE TABLE test.child_entities (
  id integer primary key,
  name text,
  parent_id integer references test.entities(id)
);

CREATE VIEW test.child_entities_view AS TABLE test.child_entities;

CREATE TABLE test.grandchild_entities (
  id integer primary key,
  name text,
  parent_id integer references test.child_entities(id)
);

-- OpenAPI description tests (COMMENT-sourced).
COMMENT ON TABLE test.child_entities IS 'child_entities comment';
COMMENT ON COLUMN test.child_entities.id IS 'child_entities id comment';
COMMENT ON COLUMN test.child_entities.name IS 'child_entities name comment. Can be longer than sixty-three characters long';

COMMENT ON VIEW test.child_entities_view IS 'child_entities_view comment';
COMMENT ON COLUMN test.child_entities_view.id IS 'child_entities_view id comment';
COMMENT ON COLUMN test.child_entities_view.name IS 'child_entities_view name comment. Can be longer than sixty-three characters long';

-- Multi-line comment: first line -> summary, rest -> description.
COMMENT ON TABLE test.grandchild_entities IS
$$grandchild_entities summary

grandchild_entities description
that spans
multiple lines$$;

-- ---------------------------------------------------------------------------
-- openapi_types: one column per PostgreSQL -> Swagger type mapping
-- Source: test/spec/fixtures/schema.sql#L1829
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- openapi_defaults: default value detection
-- Source: test/spec/fixtures/schema.sql#L1853
-- ---------------------------------------------------------------------------

CREATE TABLE test.openapi_defaults(
  "text" text default 'default',
  "boolean" boolean default false,
  "integer" integer default 42,
  "numeric" numeric default 42.2,
  "date" date default '1900-01-01'::date,
  "time" time default '13:00:00'::time without time zone
);

-- ---------------------------------------------------------------------------
-- enum type + menagerie table (enum property in definitions)
-- ---------------------------------------------------------------------------

CREATE TYPE test.enum_menagerie_type AS ENUM ('foo', 'bar');

CREATE TABLE test.menagerie(
  "integer" integer NOT NULL,
  "double" double precision NOT NULL,
  "varchar" character varying NOT NULL,
  "boolean" boolean NOT NULL,
  "date" date NOT NULL,
  "money" money NOT NULL,
  "enum" test.enum_menagerie_type NOT NULL
);

-- ---------------------------------------------------------------------------
-- RPC: varied_arguments_openapi (IMMUTABLE -> GET + POST) with comment
-- Source: test/spec/fixtures/schema.sql#L285 / #L330
-- ---------------------------------------------------------------------------

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

COMMENT ON FUNCTION test.varied_arguments_openapi(double precision, character varying, boolean, date, money, test.enum_menagerie_type, text[], int[], boolean[], char[], varchar[], bigint[], numeric[], json[], jsonb[], integer, json, jsonb) IS
  $_$An RPC function

Just a test for RPC function arguments$_$;

-- VOLATILE function -> POST only in the OpenAPI paths.
CREATE FUNCTION test.reset_table() RETURNS void
  LANGUAGE sql
  VOLATILE
AS $$ SELECT 1; $$;

-- STABLE function -> GET + POST.
CREATE FUNCTION test.getallusers() RETURNS setof test.entities
  LANGUAGE sql
  STABLE
AS $$ SELECT * FROM test.entities; $$;

-- ---------------------------------------------------------------------------
-- Privileges: anonymous role cannot see authors_only / privileged_hello.
-- A privileged role (postgrest_test_author) can.
-- Source: test/spec/fixtures/privileges.sql
-- ---------------------------------------------------------------------------

CREATE TABLE test.authors_only (
  secret text
);

CREATE FUNCTION test.privileged_hello(name text) RETURNS text
  LANGUAGE sql
AS $$ SELECT 'Privileged hello to ' || name; $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'postgrest_test_anonymous') THEN
    CREATE ROLE postgrest_test_anonymous;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'postgrest_test_author') THEN
    CREATE ROLE postgrest_test_author;
  END IF;
END $$;

GRANT USAGE ON SCHEMA test TO postgrest_test_anonymous, postgrest_test_author;

-- Anonymous gets everything except authors_only and privileged_hello.
GRANT SELECT, INSERT, UPDATE, DELETE ON
  test.entities, test.child_entities, test.child_entities_view,
  test.grandchild_entities, test.openapi_types, test.openapi_defaults,
  test.menagerie
  TO postgrest_test_anonymous, postgrest_test_author;

GRANT EXECUTE ON FUNCTION
  test.varied_arguments_openapi(double precision, character varying, boolean, date, money, test.enum_menagerie_type, text[], int[], boolean[], char[], varchar[], bigint[], numeric[], json[], jsonb[], integer, json, jsonb),
  test.reset_table(), test.getallusers()
  TO postgrest_test_anonymous, postgrest_test_author;

-- Only the privileged role may see authors_only + privileged_hello.
GRANT SELECT, INSERT, UPDATE, DELETE ON test.authors_only TO postgrest_test_author;
GRANT EXECUTE ON FUNCTION test.privileged_hello(text) TO postgrest_test_author;

-- ---------------------------------------------------------------------------
-- db-root-spec: a function whose return value overrides the entire root
-- OpenAPI document. When config db-root-spec='root' is set, GET / invokes
-- this function and returns its body verbatim instead of the generated doc.
-- Source: docs/references/api/openapi.rst#L60 (Overriding Full OpenAPI
-- Response), config db-root-spec docs/references/configuration.rst#L486,
-- dispatch src/PostgREST/ApiRequest.hs#L120-122. The function shape mirrors
-- the documented example and test/io/fixtures/load.sql#L250 root().
-- ---------------------------------------------------------------------------
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

GRANT EXECUTE ON FUNCTION test.root() TO postgrest_test_anonymous, postgrest_test_author;
