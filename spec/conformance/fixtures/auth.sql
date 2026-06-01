-- Conformance fixtures for the AUTH area (PostgREST v14.12)
--
-- Distilled from PostgREST's own fixtures so the auth conformance cases
-- can run against an identical Postgres database. Sources:
--   roles:        https://raw.githubusercontent.com/PostgREST/postgrest/v14.12/test/spec/fixtures/roles.sql
--   schema/procs: https://raw.githubusercontent.com/PostgREST/postgrest/v14.12/test/spec/fixtures/schema.sql
--   privileges:   https://raw.githubusercontent.com/PostgREST/postgrest/v14.12/test/spec/fixtures/privileges.sql
--
-- The PostgREST server under test must be configured with:
--   db-schemas        = "test"  (exposed as the default profile; cases use bare paths)
--   db-anon-role      = "postgrest_test_anonymous"
--   jwt-secret        = "reallyreallyreallyreallyverysafe"   (HS256; >=32 chars)
--   db-pre-request    = "test.switch_role"   (only for the pre-request cases; see notes)
--
-- HS256 secret matches PostgREST's testCfg default
-- (https://raw.githubusercontent.com/PostgREST/postgrest/v14.12/test/io/configs ... and
--  the SpecHelper testCfg "reallyreallyreallyreallyverysafe").

BEGIN;

-- ---------------------------------------------------------------------------
-- Roles
-- Mirrors test/spec/fixtures/roles.sql#L1-L7
-- ---------------------------------------------------------------------------
DROP ROLE IF EXISTS postgrest_test_anonymous, postgrest_test_default_role, postgrest_test_author;
CREATE ROLE postgrest_test_anonymous;
CREATE ROLE postgrest_test_default_role;
CREATE ROLE postgrest_test_author;
-- The authenticator (PGUSER running PostgREST) must be able to SET ROLE to each:
--   GRANT postgrest_test_anonymous, postgrest_test_default_role, postgrest_test_author TO <authenticator>;

DROP SCHEMA IF EXISTS test CASCADE;
CREATE SCHEMA test;
SET search_path = test, public;

-- ---------------------------------------------------------------------------
-- Tables guarded by role ownership / grants
-- authors_only: owned by / granted to postgrest_test_author only.
--   schema.sql#L505 (table) + privileges.sql#L31 (revoke from anon) +
--   privileges.sql#L51 (grant ALL to author)
-- ---------------------------------------------------------------------------
CREATE TABLE test.authors_only (
  owner  text NOT NULL DEFAULT current_setting('request.jwt.claims', true)::json->>'id',
  secret text NOT NULL,
  CONSTRAINT authors_only_pkey PRIMARY KEY (secret)
);

-- private_table: empty table, no grants to anyone (schema.sql#L596)
CREATE TABLE test.private_table ();

-- items: readable by anonymous; used to show anon access works/blocked.
CREATE TABLE test.items (id bigint PRIMARY KEY);
INSERT INTO test.items (id) SELECT generate_series(1, 15);

-- has_count_column: an anon-readable table used by AudienceJwtSecretSpec
-- ("succeeds without a JWT").
CREATE TABLE test.has_count_column (count int);

-- ---------------------------------------------------------------------------
-- pgjwt: minimal jwt.sign so SQL functions can mint tokens (login/jwt_test)
-- Mirrors test/spec/fixtures/jwt.sql (michelp/pgjwt c02bbd3)
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;

DROP SCHEMA IF EXISTS jwt CASCADE;
CREATE SCHEMA jwt;

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

-- jwt_token composite type returned by login (schema.sql, type public.jwt_token)
DROP TYPE IF EXISTS public.jwt_token CASCADE;
CREATE TYPE public.jwt_token AS (token text);

-- auth table backing login() (data.sql#L22)
DROP SCHEMA IF EXISTS postgrest CASCADE;
CREATE SCHEMA postgrest;
CREATE TABLE postgrest.auth (
  id      text PRIMARY KEY,
  rolname name NOT NULL DEFAULT 'postgrest_test_author',
  pass    text NOT NULL
);
INSERT INTO postgrest.auth (id, rolname, pass) VALUES ('jdoe', 'postgrest_test_author', '1234');

-- ---------------------------------------------------------------------------
-- RPC functions exercised by the auth cases
-- ---------------------------------------------------------------------------

-- login(): mints an HS256 token whose role claim = rolname (schema.sql#L236)
CREATE OR REPLACE FUNCTION test.login(id text, pass text) RETURNS public.jwt_token
  LANGUAGE sql SECURITY DEFINER STABLE AS $$
  SELECT jwt.sign(row_to_json(r), 'reallyreallyreallyreallyverysafe') AS token
  FROM (
    SELECT rolname::text, id::text
      FROM postgrest.auth a
     WHERE a.id = login.id AND a.pass = login.pass
  ) r;
$$;

-- jwt_test(): encodes a fixed set of custom + standard claims (schema.sql#L350)
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

-- reveal_big_jwt(): reads standard + custom claims from request.jwt.claims
-- (schema.sql#L393)
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

-- get_current_user(): returns the role PostgREST switched into (schema.sql#L382)
CREATE OR REPLACE FUNCTION test.get_current_user() RETURNS text
  LANGUAGE sql STABLE AS $$ SELECT current_user::text; $$;

-- switch_role(): db-pre-request proc that reads the id claim and SET ROLE
-- (schema.sql#L363)
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

-- privileged_hello(): execute revoked from PUBLIC, granted only to author
-- (schema.sql#L1222, privileges.sql#L61-L62)
CREATE OR REPLACE FUNCTION test.privileged_hello(name text) RETURNS text
  LANGUAGE sql AS $$ SELECT 'Privileged hello to ' || $1; $$;

-- get_guc_value(): reads a GUC, optionally a JSON member of a GUC prefix
-- (schema.sql#L1143 and #L1148)
CREATE OR REPLACE FUNCTION test.get_guc_value(name text) RETURNS text
  LANGUAGE sql AS $$ SELECT nullif(current_setting(name), '')::text; $$;

CREATE OR REPLACE FUNCTION test.get_guc_value(prefix text, name text) RETURNS text
  LANGUAGE sql AS $$ SELECT nullif(current_setting(prefix)::json->>name, '')::text; $$;

-- ---------------------------------------------------------------------------
-- Privileges (privileges.sql)
-- ---------------------------------------------------------------------------
GRANT USAGE ON SCHEMA test, public, jwt, postgrest TO postgrest_test_anonymous;
GRANT USAGE ON SCHEMA test TO postgrest_test_author;
GRANT USAGE ON SCHEMA test TO postgrest_test_default_role;

-- anonymous: can read items / has_count_column, NOT authors_only/private_table
GRANT SELECT ON TABLE test.items TO postgrest_test_anonymous;
GRANT SELECT, INSERT ON TABLE test.has_count_column TO postgrest_test_anonymous;

-- author: owns authors_only
GRANT ALL ON TABLE test.authors_only TO postgrest_test_author;

-- privileged_hello: revoke from PUBLIC, grant to author
REVOKE EXECUTE ON FUNCTION test.privileged_hello(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION test.privileged_hello(text) TO postgrest_test_author;

-- All other RPCs are PUBLIC by default; anon may call login/jwt_test/get_guc_value/
-- reveal_big_jwt/get_current_user/switch_role.

COMMIT;
