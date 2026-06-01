-- Fixtures for the "content_negotiation" feature area.
-- Pinned to PostgREST v14.12. Derived from PostgREST's own test fixtures, a
-- minimal subset sufficient for the cases in spec/conformance/cases/16xx_*.yaml.
--
-- Source anchors (upstream fixture lines, schema.sql unless noted):
--   items / simple_pk:   test/spec/fixtures/schema.sql
--   addresses:           test/spec/fixtures/schema.sql
--   projects/clients:    test/spec/fixtures/schema.sql
--   shops (PostGIS):     test/spec/fixtures/schema.sql (requires postgis ext)
--   getproject (RPC):    test/spec/fixtures/schema.sql
--   sayhello   (RPC):    test/spec/fixtures/schema.sql
--   unnamed_bytea_param: test/spec/fixtures/schema.sql

CREATE SCHEMA IF NOT EXISTS test;
SET search_path = test, public;

-- items: single bigserial PK. Used for singular object + CSV + plan cases.
CREATE TABLE items (
    id bigserial primary key
);
INSERT INTO items (id)
  SELECT g FROM generate_series(1, 15) g;
SELECT setval('items_id_seq', 15);

-- simple_pk: text PK with an extra column. Used for the CSV body case
-- (k,extra header + row data must match exactly).
CREATE TABLE simple_pk (
    k       text NOT NULL primary key,
    extra   text NOT NULL
);
INSERT INTO simple_pk (k, extra) VALUES ('xyyx', 'u'), ('xYYx', 'v');

-- addresses: integer PK + address column. Used for singular PATCH/POST cases.
CREATE TABLE addresses (
    id      integer primary key,
    address text NOT NULL
);
INSERT INTO addresses (id, address) VALUES
  (1, 'address 1'), (2, 'address 2'), (3, 'address 3'), (4, 'address 4');

-- clients + projects: used by singular-object plurality + plan + CSV cases.
CREATE TABLE clients (
    id   integer primary key,
    name text NOT NULL
);
INSERT INTO clients (id, name) VALUES (1, 'Microsoft'), (2, 'Apple');

CREATE TABLE projects (
    id        integer primary key,
    name      text NOT NULL,
    client_id integer REFERENCES clients(id)
);
INSERT INTO projects (id, name, client_id) VALUES
  (1, 'Windows 7', 1),
  (2, 'Windows 10', 1),
  (3, 'IOS', 2),
  (4, 'OSX', 2),
  (5, 'Orphan', NULL);

-- no_pk: two text columns, no PK. Used for CSV insert representation.
CREATE TABLE no_pk (
    a text,
    b text
);

-- getproject: RPC returning a single project row by id (json proc).
CREATE OR REPLACE FUNCTION getproject(id int) RETURNS SETOF projects AS $$
  SELECT * FROM test.projects WHERE id = getproject.id;
$$ LANGUAGE sql STABLE;

-- getallprojects: RPC returning all projects (setof, multiple rows).
CREATE OR REPLACE FUNCTION getallprojects() RETURNS SETOF projects AS $$
  SELECT * FROM test.projects;
$$ LANGUAGE sql STABLE;

-- sayhello: scalar text RPC, used to show vnd.pgrst.object on a scalar result.
CREATE OR REPLACE FUNCTION sayhello(name text) RETURNS text AS $$
  SELECT 'Hello, ' || name;
$$ LANGUAGE sql IMMUTABLE;

-- bytea passthrough RPC: single unnamed bytea parameter, echoes the body.
-- Used for application/octet-stream request+response cases.
CREATE OR REPLACE FUNCTION unnamed_bytea_param(bytea) RETURNS bytea AS $$
  SELECT $1;
$$ LANGUAGE sql IMMUTABLE;

-- managers + organizations: self-referencing org tree with nullable referee /
-- auditor columns. Mirrors test/spec/fixtures/schema.sql organizations table
-- (the PostGIS-free subset). Drives the nulls=stripped cases (1630..1635):
-- rows 1 and 2 have NULL referee/auditor so stripped output omits those keys.
CREATE TABLE managers (
    id   integer primary key,
    name text
);
INSERT INTO managers (id, name) VALUES
  (1, 'Referee Manager'), (2, 'Auditor Manager'), (3, 'Acme Manager'),
  (4, 'Umbrella Manager'), (5, 'Cyberdyne Manager'), (6, 'Oscorp Manager');

CREATE TABLE organizations (
    id         integer primary key,
    name       text,
    referee    integer REFERENCES organizations(id),
    auditor    integer REFERENCES organizations(id),
    manager_id integer REFERENCES managers(id)
);
INSERT INTO organizations (id, name, referee, auditor, manager_id) VALUES
  (1, 'Referee Org', NULL, NULL, 1),
  (2, 'Auditor Org', NULL, NULL, 2),
  (3, 'Acme',        1,    2,    3),
  (4, 'Umbrella',    1,    2,    4),
  (5, 'Cyberdyne',   3,    4,    5),
  (6, 'Oscorp',      3,    4,    6);

-- get_lines: setof RPC whose result row type has NO custom media-type
-- aggregate handler. Used by case 1624 (Accept application/octet-stream -> 406
-- PGRST107). Upstream get_lines returns a PostGIS geometry-bearing row; here we
-- use a plain table because the 406 is decided during content negotiation
-- (before execution), so the row type's columns are irrelevant to the assertion.
CREATE TABLE lines (
    id   int primary key,
    name text
);
INSERT INTO lines (id, name) VALUES (1, 'line-1'), (2, 'line-2');

CREATE OR REPLACE FUNCTION get_lines() RETURNS SETOF lines AS $$
  SELECT * FROM test.lines;
$$ LANGUAGE sql STABLE;

-- -------------------------------------------------------------------------
-- Custom media type handlers (CustomMediaSpec). PostgREST models custom
-- media types as DOMAINs and the handlers as AGGREGATEs over the row type
-- (or over anyelement). Mirrors test/spec/fixtures/schema.sql domains at
-- L114-L122 and the aggregate handlers at L3449-L3491.
--
-- The upstream fixtures wrap PostGIS calls (ST_AsGeoJSON / ST_AsTWKB) in the
-- transition functions, but the asserted behavior for the cases below is
-- decided by the final/initcond values, so this PostGIS-free subset is
-- faithful to the negotiation + Content-Type contract being exercised.
-- -------------------------------------------------------------------------

-- Custom media-type domains (the Content-Type a handler produces).
CREATE DOMAIN "application/vnd.geo2+json" AS jsonb;
CREATE DOMAIN "application/json"          AS json;
CREATE DOMAIN "*/*"                        AS bytea;

-- (b) anyelement handler for application/vnd.geo2+json.
-- An aggregate over anyelement so it applies to any table/RPC result. The
-- final function ignores the accumulated state and returns a constant
-- FeatureCollection, matching CustomMediaSpec 'works if there's an anyelement
-- aggregate defined' (GET /rpc/get_lines, Accept application/vnd.geo2+json).
CREATE OR REPLACE FUNCTION geo2json_trans(state "application/vnd.geo2+json", next anyelement)
RETURNS "application/vnd.geo2+json" AS $$
  SELECT (state || to_jsonb(next))::"application/vnd.geo2+json";
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION geo2json_final(data "application/vnd.geo2+json")
RETURNS "application/vnd.geo2+json" AS $$
  SELECT (jsonb_build_object('type', 'FeatureCollection', 'hello', 'world'))::"application/vnd.geo2+json";
$$ LANGUAGE sql;

CREATE AGGREGATE geo2json_agg_any(anyelement) (
  initcond  = '[]',
  stype     = "application/vnd.geo2+json",
  sfunc     = geo2json_trans,
  finalfunc = geo2json_final
);

-- (c) override the builtin application/json handler for a single table.
-- ov_json is a columnless, rowless table; its aggregate has no finalfunc, so
-- over zero input rows it returns the initcond verbatim. Mirrors
-- CustomMediaSpec 'will override the application/json handler for a single
-- table' (GET /ov_json -> {"overridden": "true"}).
CREATE TABLE ov_json ();

CREATE OR REPLACE FUNCTION ov_json_trans(state "application/json", next ov_json)
RETURNS "application/json" AS $$
  SELECT NULL::"application/json";
$$ LANGUAGE sql;

CREATE AGGREGATE ov_json_agg(ov_json) (
  initcond = '{"overridden": "true"}',
  stype    = "application/json",
  sfunc    = ov_json_trans
);

-- (d) the Any ("*/*") handler defaulting to application/octet-stream.
-- A function returning the "*/*" domain. When the client sends Accept: */*
-- (or any media type) and the handler does NOT set response.headers, PostgREST
-- falls back to application/octet-stream. Mirrors CustomMediaSpec functions
-- context 'returns application/json for */* if not explicitly set' and
-- 'accepts any media type and sets the generic octet-stream as content type'
-- (GET /rpc/ret_any_mt).
CREATE OR REPLACE FUNCTION ret_any_mt()
RETURNS "*/*" AS $$
  SELECT 'any'::"*/*";
$$ LANGUAGE sql;

-- -------------------------------------------------------------------------
-- PostGIS-dependent objects (GeoJSON cases). These require the postgis
-- extension; cases that touch them carry preconditions noting the dependency.
-- -------------------------------------------------------------------------
-- CREATE EXTENSION IF NOT EXISTS postgis;
-- CREATE TABLE shops (
--     id        int primary key,
--     address   text,
--     shop_geom geometry(POINT, 4326)
-- );
-- INSERT INTO shops (id, address, shop_geom) VALUES
--   (1, '1369 Cambridge St',     'SRID=4326;POINT(-71.10044 42.373695)'),
--   (2, '757 Massachusetts Ave', 'SRID=4326;POINT(-71.10543 42.366432)'),
--   (3, '605 W Kendall St',      'SRID=4326;POINT(-71.081924 42.36437)');
