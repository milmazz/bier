-- Conformance fixtures for the "filters" feature area (PostgREST v14.12).
--
-- This is a self-contained subset of PostgREST's own test fixtures, restricted
-- to exactly the tables and rows the filter conformance cases (1150..1199) need.
-- Every table/row below is copied verbatim (same shape, same data) from:
--   schema: https://github.com/PostgREST/postgrest/blob/v14.12/test/spec/fixtures/schema.sql
--   data:   https://github.com/PostgREST/postgrest/blob/v14.12/test/spec/fixtures/data.sql
--
-- Loads cleanly into Postgres 14/15/16. Run inside a schema named `test`
-- (PostgREST's default test schema) or adjust search_path in the harness.

-- ---------------------------------------------------------------------------
-- entities / child_entities / grandchild_entities
-- schema.sql L1167-1189 ; data.sql L356-375
-- ---------------------------------------------------------------------------

create table entities (
  id integer primary key,
  name text,
  arr integer[],
  text_search_vector tsvector
);

create table child_entities (
  id integer primary key,
  name text,
  parent_id integer references entities(id)
);

create table grandchild_entities (
  id integer primary key,
  name text,
  parent_id integer references child_entities(id),
  or_starting_col text,
  and_starting_col text,
  jsonb_col jsonb
);

insert into entities values (1, 'entity 1', '{1}', '''bar'':2 ''foo'':1');
insert into entities values (2, 'entity 2', '{1,2}', '''baz'':1 ''qux'':2');
insert into entities values (3, 'entity 3', '{1,2,3}', null);
insert into entities values (4, null, null, null);

insert into child_entities values (1, 'child entity 1', 1);
insert into child_entities values (2, 'child entity 2', 1);
insert into child_entities values (3, 'child entity 3', 2);
insert into child_entities values (4, 'child entity 4', 1);
insert into child_entities values (5, 'child entity 5', 1);
insert into child_entities values (6, 'child entity 6', 2);

insert into grandchild_entities values (1, 'grandchild entity 1', 1, null, null, null);
insert into grandchild_entities values (2, 'grandchild entity 2', 1, null, null, null);
insert into grandchild_entities values (3, 'grandchild entity 3', 2, null, null, null);
insert into grandchild_entities values (4, '(grandchild,entity,4)', 2, null, null, '{"a": {"b":"foo"}}');
insert into grandchild_entities values (5, '(grandchild,entity,5)', 2, null, null, '{"b":"bar"}');

-- ---------------------------------------------------------------------------
-- ranges (range operators)
-- schema.sql L1193-1196 ; data.sql L377-382
-- ---------------------------------------------------------------------------

create table ranges (
  id integer primary key,
  range numrange
);

insert into ranges values (1, '[1,3]');
insert into ranges values (2, '[3,6]');
insert into ranges values (3, '[6,9]');
insert into ranges values (4, '[9,12]');
insert into ranges values (5, null);

-- ---------------------------------------------------------------------------
-- simple_pk (like/ilike/match/imatch + not)
-- schema.sql L769-773 ; data.sql L185-186
-- ---------------------------------------------------------------------------

create table simple_pk (
  primary key (k),
  k character varying not null,
  extra character varying not null
);

insert into simple_pk values ('xyyx', 'u');
insert into simple_pk values ('xYYx', 'v');

-- ---------------------------------------------------------------------------
-- no_pk (is null / is not_null / isdistinct)
-- schema.sql L688-691 ; data.sql L280-282
-- ---------------------------------------------------------------------------

create table no_pk (
  a character varying,
  b character varying
);

insert into no_pk values (null, null);
insert into no_pk values ('1', '0');
insert into no_pk values ('2', '0');

-- ---------------------------------------------------------------------------
-- chores (is.true/false/unknown, case-insensitive trilean)
-- schema.sql L2457-2461 ; data.sql L736
-- ---------------------------------------------------------------------------

create table chores (
  id int primary key,
  name text,
  done bool
);

insert into chores (id, name, done) values
  (1, 'take out the garbage', true),
  (2, 'do the laundry', false),
  (3, 'wash the dishes', null);

-- ---------------------------------------------------------------------------
-- json_table / json_arr / jsonb_test (JSON arrow filters)
-- schema.sql L655-657, L1548-1556 ; data.sql L263-266, L506-521
-- ---------------------------------------------------------------------------

create table json_table (
  data json
);

insert into json_table values ('{"foo":{"bar":"baz"},"id":1}');
insert into json_table values ('{"id":3}');
insert into json_table values ('{"id":0}');

create table json_arr (
  id integer primary key,
  data json
);

insert into json_arr values (1, '[1, 2, 3]');
insert into json_arr values (2, '[4, 5, 6]');
insert into json_arr values (3, '[[9, 8, 7], [11, 12, 13]]');
insert into json_arr values (4, '[[[5, 6], 7, 8]]');
insert into json_arr values (5, '[{"a": "A"}, {"b": "B"}]');
insert into json_arr values (6, '[{"a": [1,2,3]}, {"b": [4,5]}]');
insert into json_arr values (7, '{"c": [1,2,3], "d": [4,5]}');
insert into json_arr values (8, '{"c": [{"d": [4,5,6,7,8]}]}');
insert into json_arr values (9, '[{"0xy1": [1,{"23-xy-45": [2, {"xy-6": [3]}]}]}]');
insert into json_arr values (10, '{"!@#$%^&*_a": [{"!@#$%^&*_b": 1}, {"!@#$%^&*_c": [2]}], "!@#$%^&*_d": {"!@#$%^&*_e": 3}}');

create table jsonb_test (
  id integer primary key,
  data jsonb
);

insert into jsonb_test values (1, '{ "a": {"b": 2} }');
insert into jsonb_test values (2, '{ "c": [1,2,3] }');
insert into jsonb_test values (3, '[{ "d": "test" }]');
insert into jsonb_test values (4, '{ "e": 1 }');
