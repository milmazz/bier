-- Fixtures for the "headers" feature area.
-- Covers: request/response headers, Prefer echo (Preference-Applied),
-- Content-Profile / Accept-Profile schema switching, Location on insert,
-- Content-Location, GUC response.headers / response.status overrides.
--
-- Derived from PostgREST v14.12 test/spec/fixtures/schema.sql + data.sql.
-- Tables are a minimal self-contained subset sufficient for the cases in
-- spec/conformance/cases/15xx_*.yaml.
--
-- Source anchors (v14.12 test/spec/fixtures):
--   projects:                       schema.sql#L719
--   timestamps:                     schema.sql#L3578  data.sql#L841
--   tiobe_pls:                      schema.sql#L1437
--   loc_test:                       schema.sql#L2106
--   private.stuff / test.stuff:     schema.sql#L2074  schema.sql#L2079
--   location_for_stuff trigger:     schema.sql#L2081
--   status_205_for_updated_stuff:   schema.sql#L2097
--   send_body_status_403:           schema.sql#L1303
--   send_bad_status:                schema.sql#L1310
--   get_projects_and_guc_headers:   schema.sql#L1317
--   get_int_and_guc_headers:        schema.sql#L1322
--   bad_guc_headers_1:              schema.sql#L1327
--   set_cookie_twice:               schema.sql#L1339
--   v1.parents / v2.parents:        schema.sql#L2112 / schema.sql#L2130
--   v2.another_table:               schema.sql#L2143
--   SPECIAL "@/\#~_-".names:        MultipleSchemaSpec.hs#L82 (special-named schema)

CREATE SCHEMA IF NOT EXISTS test;
-- multi-schema exposure: v1 is the default (first) schema, v2 secondary.
CREATE SCHEMA IF NOT EXISTS v1;
CREATE SCHEMA IF NOT EXISTS v2;

SET search_path = test, public;

-- ---------------------------------------------------------------------------
-- Tables in the default "test" schema
-- ---------------------------------------------------------------------------

-- clients + projects: FK pair; projects has an integer PK used for Location.
CREATE TABLE test.clients (
    id integer primary key,
    name text NOT NULL
);
INSERT INTO test.clients (id, name) VALUES (1, 'Microsoft'), (2, 'Apple');

CREATE TABLE test.projects (
    id integer primary key,
    name text NOT NULL,
    client_id integer REFERENCES test.clients(id)
);
INSERT INTO test.projects (id, name, client_id) VALUES
  (1, 'Windows 7', 1),
  (2, 'Windows 10', 1),
  (3, 'IOS', 2);

-- car_models: compound primary key (name, year). Used for Location with
-- multiple PK columns on insert. (Upstream uses a partitioned table; a plain
-- compound-PK table is sufficient for the Location-building behavior.)
CREATE TABLE test.car_models (
    name text,
    year integer,
    primary key (name, year)
);

-- no_pk: no primary key. Used for Content-Location canonicalization.
CREATE TABLE test.no_pk (
    a text,
    b text
);

-- simple_pk: single text PK. Content-Location without params.
CREATE TABLE test.simple_pk (
    k text primary key,
    extra text
);
INSERT INTO test.simple_pk (k, extra) VALUES ('xyz', 'u'), ('abc', 'v');

-- items: integer PK, many rows. Used for max-affected delete + Prefer handling.
CREATE TABLE test.items (
    id integer primary key
);
INSERT INTO test.items (id)
  SELECT generate_series(1, 15);

-- tiobe_pls: PATCH target for max-affected with handling=strict.
CREATE TABLE test.tiobe_pls (
    name text primary key,
    rank integer
);
INSERT INTO test.tiobe_pls (name, rank) VALUES ('Java', 1), ('C', 2);

-- timestamps: single timestamptz column for Prefer: timezone echo.
CREATE TABLE test.timestamps (
    t timestamp with time zone
);
INSERT INTO test.timestamps VALUES
  ('2023-10-18 12:37:59.611000+0000'),
  ('2023-10-18 14:37:59.611000+0000'),
  ('2023-10-18 16:37:59.611000+0000');

-- loc_test: blank-header regression target (mutations should not add `:`).
CREATE TABLE test.loc_test (
    id int primary key,
    c text
);

-- private.stuff exposed via test.stuff view + INSTEAD OF triggers that
-- override Location (on insert) and response.status (on update) via GUCs.
CREATE SCHEMA IF NOT EXISTS private;
CREATE TABLE private.stuff (
    id integer primary key,
    name text
);
INSERT INTO private.stuff (id, name) VALUES (1, 'stuff 1');

CREATE VIEW test.stuff AS SELECT * FROM private.stuff;

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

-- ---------------------------------------------------------------------------
-- RPC functions exercising GUC response.headers / response.status
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- Multi-schema tables for Accept-Profile / Content-Profile switching.
-- Exposed schemas (in order): v1, v2.  v1 is the default.
-- ---------------------------------------------------------------------------

CREATE TABLE v1.parents (
    id    int primary key,
    name  text
);
INSERT INTO v1.parents (id, name) VALUES (1, 'parent v1-1'), (2, 'parent v1-2');

CREATE TABLE v1.children (
    id int primary key,
    name text,
    parent_id int,
    constraint parent foreign key(parent_id) references v1.parents(id)
);

CREATE TABLE v2.parents (
    id    int primary key,
    name  text
);
INSERT INTO v2.parents (id, name) VALUES (3, 'parent v2-3'), (4, 'parent v2-4');

CREATE TABLE v2.children (
    id int primary key,
    name text,
    parent_id int,
    constraint parent foreign key(parent_id) references v2.parents(id)
);

CREATE TABLE v2.another_table (
    id            int primary key,
    another_value text
);
INSERT INTO v2.another_table (id, another_value) VALUES (5, 'value 5'), (6, 'value 6');

-- ---------------------------------------------------------------------------
-- Schema whose name contains uppercase + special characters: SPECIAL "@/\#~_-
-- Exposed as a third schema (after v1, v2) so a profile header may name it and
-- be echoed verbatim in Content-Profile. Mirrors PostgREST's own fixture
-- (test/spec/fixtures/schema.sql) which exposes the same special-named schema.
-- Source: test/spec/Feature/Query/MultipleSchemaSpec.hs#L82
-- ---------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS "SPECIAL ""@/\#~_-";

CREATE TABLE "SPECIAL ""@/\#~_-".names (
    id   int primary key,
    name text
);
INSERT INTO "SPECIAL ""@/\#~_-".names (id, name) VALUES
  (1, 'John'), (2, 'Mary'), (3, 'José');
