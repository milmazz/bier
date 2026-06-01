-- Bier conformance fixtures: mutations feature area
-- Mirrors a minimal subset of PostgREST v14.12 test/spec/fixtures/schema.sql
-- needed by spec/conformance/cases/1350..1399.
--
-- Source of truth (table shapes):
--   https://github.com/PostgREST/postgrest/blob/v14.12/test/spec/fixtures/schema.sql
--
-- All objects live in schema `test` to match PostgREST's exposed schema and
-- the error messages that reference `test.<table>` (e.g. PGRST205).
--
-- TEST ISOLATION CONTRACT (read before running the 1350..1399 band):
-- These cases MUTATE shared seeded tables (items, tiobe_pls, articles,
-- single_unique, compound_unique, ...). To keep them order-independent the
-- runner SHOULD wrap each case in a transaction that is ROLLED BACK after the
-- assertion (the PostgREST suite itself runs every it-block in a rolled-back
-- transaction). As defence-in-depth, every order-sensitive case ALSO carries
-- explicit `preconditions` that reset just the rows it depends on, so a runner
-- without per-case rollback still produces the documented status/body. Do not
-- rely on the seed alone for any mutating assertion.

create schema if not exists test;
set search_path = test, public;

-- items: simple auto-incrementing integer pk. Used for plain INSERT/UPDATE/DELETE,
-- empty-body PATCH, content-range and max-affected cases.
-- schema.sql:126
create table test.items (
  id serial primary key
);
insert into test.items (id)
  select generate_series(1, 15);

-- no_pk: a table with NO primary key. Used for bulk insert with no Location,
-- "succeeds with 201 but no location header", and PUT-no-pk error.
-- schema.sql:688
create table test.no_pk (
  a text,
  b text
);

-- simple_pk: single text pk + extra column. Used for 409 duplicate pk and
-- not-null violation (23502) and empty/invalid json body errors.
-- schema.sql:769
create table test.simple_pk (
  k text not null primary key,
  extra text not null
);
insert into test.simple_pk (k, extra) values ('xyyx', 'u'), ('xYYx', 'v');

-- articles: integer pk used by ?columns= tests (ignore extra json keys,
-- non-uniform array error, column-not-found, blank columns).
-- (PostgREST's articles has an `owner` defaulted to current_user; for Bier
-- conformance we default it to a constant to keep cases deterministic.)
create table test.articles (
  id integer not null primary key,
  body text,
  owner name not null default 'postgrest_test_anonymous'
);

-- complex_items: pk + name + a column whose name contains a separator,
-- plus jsonb/array columns with defaults. Used for missing=default and
-- select-shaping on DELETE.
-- schema.sql:555
create table test.complex_items (
  id bigint not null primary key,
  name text,
  settings jsonb,
  arr_data integer[],
  "field-with_sep" bigint not null default 1
);
insert into test.complex_items (id, name, settings, arr_data) values
  (1, 'One',   '{"foo":{"int":1,"bar":"baz"}}', '{1,2,3}'),
  (2, 'Two',   '{"foo":{"int":1,"bar":"baz"}}', '{1,2,3}'),
  (3, 'Three', '{"foo":{"int":1,"bar":"baz"}}', '{1,2,3}');

-- tiobe_pls: single text pk + rank. The canonical UPSERT/PUT table.
-- schema.sql:1437
-- Seed mirrors PostgREST's own data.sql exactly so the upsert/PUT statuses
-- (201 = something inserted, 200 = all updates) match upstream:
--   data.sql:403  INSERT INTO tiobe_pls VALUES ('Java', 1), ('C', 2), ('Python', 4);
-- https://github.com/PostgREST/postgrest/blob/v14.12/test/spec/fixtures/data.sql#L403
-- IMPORTANT: 'Javascript' and 'Go' are intentionally NOT seeded; cases that
-- insert them rely on their absence to assert 201. The mutating cases also
-- reset this table via `preconditions` so run order cannot flip a status.
create table test.tiobe_pls (
  name text primary key,
  rank smallint
);
insert into test.tiobe_pls (name, rank) values
  ('Java', 1),
  ('C', 2),
  ('Python', 4);

-- single_unique: integer UNIQUE (not the pk) for on_conflict=unique_key.
-- schema.sql:1442
create table test.single_unique (
  unique_key integer unique not null,
  value text
);
insert into test.single_unique (unique_key, value) values (1, 'A');

-- compound_unique: composite UNIQUE for on_conflict=key1,key2.
-- schema.sql:1447
create table test.compound_unique (
  key1 integer not null,
  key2 integer not null,
  value text,
  unique (key1, key2)
);
insert into test.compound_unique (key1, key2, value) values (1, 1, 'A');

-- only_pk: a table whose only column is its pk. Upsert/PUT edge case.
-- schema.sql:693 ; seed matches data.sql:412  INSERT INTO only_pk VALUES (1), (2);
-- https://github.com/PostgREST/postgrest/blob/v14.12/test/spec/fixtures/data.sql#L412
create table test.only_pk (
  id integer not null primary key
);
insert into test.only_pk (id) values (1), (2);

-- safe_update_items / safe_delete_items: tables used to exercise
-- pg-safeupdate (full-table UPDATE/DELETE rejected without WHERE -> 21000).
-- schema.sql:2695, schema.sql:2701
create table test.safe_update_items (
  id integer not null primary key,
  name text not null
);
insert into test.safe_update_items (id, name) values (1, 'item-1'), (2, 'item-2');

create table test.safe_delete_items (
  id integer not null primary key,
  name text not null
);
insert into test.safe_delete_items (id, name) values (1, 'item-1'), (2, 'item-2');
