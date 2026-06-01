-- Fixture for the "observability" conformance cases (band 1750..1799).
--
-- Mirrors the subset of PostgREST's test schema exercised by
-- ServerTimingSpec.hs and ObservabilitySpec.hs:
--   organizations, items, no_pk, tiobe_pls, projects, and the RPC functions
--   ret_point_overloaded(x int, y int), add_them(a int, b int),
--   getallprojects(), and sleep(seconds).
--
-- Schema name: observability  (the conformance runner exposes this as the
-- PostgREST `db-schemas` for these cases). All cases run with
-- server-timing-enabled=true and server-trace-header="X-Request-Id".
--
-- Sources:
--   organizations columns/keys:
--     https://github.com/PostgREST/postgrest/blob/v14.12/test/spec/fixtures/schema.sql#L1466
--   organizations row 6 (Oscorp):
--     https://github.com/PostgREST/postgrest/blob/v14.12/test/spec/fixtures/data.sql#L435
--   items:
--     https://github.com/PostgREST/postgrest/blob/v14.12/test/spec/fixtures/schema.sql#L126
--   no_pk:
--     https://github.com/PostgREST/postgrest/blob/v14.12/test/spec/fixtures/schema.sql#L688
--   add_them:
--     https://github.com/PostgREST/postgrest/blob/v14.12/test/spec/fixtures/schema.sql#L1862
--   ret_point_overloaded:
--     https://github.com/PostgREST/postgrest/blob/v14.12/test/spec/fixtures/schema.sql#L1109
--   getallprojects:
--     https://github.com/PostgREST/postgrest/blob/v14.12/test/spec/fixtures/schema.sql#L1037

DROP SCHEMA IF EXISTS observability CASCADE;
CREATE SCHEMA observability;
SET search_path = observability, public;

-- organizations: self-referential FKs (referee, auditor, manager_id).
CREATE TABLE organizations (
  id         integer PRIMARY KEY,
  name       text NOT NULL,
  referee    integer REFERENCES organizations (id),
  auditor    integer REFERENCES organizations (id),
  manager_id integer
);

INSERT INTO organizations (id, name, referee, auditor, manager_id) VALUES
  (1, 'Referee Org', NULL, NULL, NULL),
  (2, 'Auditor Org', NULL, NULL, NULL),
  (3, 'Acme',        NULL, NULL, NULL),
  (4, 'Umbrella',    NULL, NULL, NULL),
  (6, 'Oscorp',      3,    4,    6);

-- items: simple serial-keyed table.
CREATE TABLE items (
  id serial PRIMARY KEY
);
INSERT INTO items (id) SELECT generate_series(1, 5);

-- no_pk: a table without a primary key (PATCH addressed by a column filter).
CREATE TABLE no_pk (
  a text,
  b text
);
INSERT INTO no_pk (a, b) VALUES ('1', '0');

-- tiobe_pls: name is the PK (PUT addresses a single row by name).
CREATE TABLE tiobe_pls (
  name text PRIMARY KEY,
  rank integer
);
INSERT INTO tiobe_pls (name, rank) VALUES ('Python', 1);

-- projects: used by getallprojects() and bare reads.
CREATE TABLE projects (
  id   integer PRIMARY KEY,
  name text
);
INSERT INTO projects (id, name) VALUES
  (1, 'Windows 7'),
  (2, 'Windows 10'),
  (3, 'IOS');

-- A composite type used by the overloaded RPC.
CREATE TYPE point_2d AS (x integer, y integer);

-- RPC: ret_point_overloaded(x int, y int) -> point_2d
CREATE FUNCTION ret_point_overloaded(x integer, y integer) RETURNS point_2d AS $$
  SELECT row(x, y)::observability.point_2d;
$$ LANGUAGE sql;

-- RPC: add_them(a int, b int) -> int  (GET-callable scalar)
CREATE FUNCTION add_them(a integer, b integer) RETURNS integer AS $$
  SELECT a + b;
$$ LANGUAGE sql;

-- RPC: getallprojects() -> setof projects
CREATE FUNCTION getallprojects() RETURNS SETOF projects AS $$
  SELECT * FROM observability.projects;
$$ LANGUAGE sql;

-- RPC: sleep(seconds) -> void  (drives Server-Timing transaction duration).
CREATE FUNCTION sleep(seconds double precision) RETURNS void AS $$
  SELECT pg_sleep(seconds);
$$ LANGUAGE sql;
