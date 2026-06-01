-- Ordering feature-area fixtures for Bier conformance tests.
--
-- Derived from PostgREST v14.12 test fixtures. Only the schema/data needed by
-- the ordering cases (band 1200..1249) is included here. Where columns are
-- omitted from the upstream tables they are also omitted here, since the
-- ordering cases never reference them.
--
-- Upstream sources:
--   schema: https://raw.githubusercontent.com/PostgREST/postgrest/v14.12/test/spec/fixtures/schema.sql
--   data:   https://raw.githubusercontent.com/PostgREST/postgrest/v14.12/test/spec/fixtures/data.sql
--
-- Tables exposed under schema "test" (PostgREST's default db-schema in the test suite).

CREATE SCHEMA IF NOT EXISTS test;
SET search_path = test, pg_catalog;

-- items: single bigserial pk. Used for asc/desc and computed-column ordering.
-- https://raw.githubusercontent.com/PostgREST/postgrest/v14.12/test/spec/fixtures/schema.sql#L126
CREATE TABLE test.items (
    id bigserial primary key
);

-- anti_id computed column over items: SELECT $1.id * -1
-- https://raw.githubusercontent.com/PostgREST/postgrest/v14.12/test/spec/fixtures/schema.sql#L162
CREATE FUNCTION test.anti_id(test.items) RETURNS bigint
    LANGUAGE sql IMMUTABLE
    AS $_$ SELECT $1.id * -1 $_$;

-- always_true computed column over items: SELECT true
-- https://raw.githubusercontent.com/PostgREST/postgrest/v14.12/test/spec/fixtures/schema.sql#L145
CREATE FUNCTION test.always_true(test.items) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    AS $$ SELECT true $$;

-- no_pk: nullable text columns. Used for nullsfirst/nullslast.
-- https://raw.githubusercontent.com/PostgREST/postgrest/v14.12/test/spec/fixtures/schema.sql#L688
CREATE TABLE test.no_pk (
    a character varying,
    b character varying
);

-- clients / projects / tasks / users: relationship chain used for embed.order
-- and related (to-one) ordering.
-- https://raw.githubusercontent.com/PostgREST/postgrest/v14.12/test/spec/fixtures/schema.sql#L546
CREATE TABLE test.clients (
    id integer primary key,
    name text NOT NULL
);

-- https://raw.githubusercontent.com/PostgREST/postgrest/v14.12/test/spec/fixtures/schema.sql#L719
CREATE TABLE test.projects (
    id integer primary key,
    name text NOT NULL,
    client_id integer REFERENCES test.clients(id)
);

-- https://raw.githubusercontent.com/PostgREST/postgrest/v14.12/test/spec/fixtures/schema.sql#L781
CREATE TABLE test.users (
    id integer primary key,
    name text NOT NULL
);

-- https://raw.githubusercontent.com/PostgREST/postgrest/v14.12/test/spec/fixtures/schema.sql#L792
CREATE TABLE test.tasks (
    id integer primary key,
    name text NOT NULL,
    project_id integer REFERENCES test.projects(id)
);

-- m2m join table users <-> tasks
-- https://raw.githubusercontent.com/PostgREST/postgrest/v14.12/test/spec/fixtures/schema.sql#L809
CREATE TABLE test.users_tasks (
    user_id integer NOT NULL REFERENCES test.users(id),
    task_id integer NOT NULL REFERENCES test.tasks(id),
    primary key (user_id, task_id)
);

-- json_table: single json column. Used for JSON-arrow ordering.
-- https://raw.githubusercontent.com/PostgREST/postgrest/v14.12/test/spec/fixtures/schema.sql#L655
CREATE TABLE test.json_table (
    data json
);

-- complex composite type + fav_numbers: used for ordering on a composite-type
-- field via JSON arrow (order=num->i.asc / order=num->>i.desc).
-- https://raw.githubusercontent.com/PostgREST/postgrest/v14.12/test/spec/fixtures/schema.sql#L2489
CREATE TYPE test.complex AS (
    r double precision,
    i double precision
);

-- https://raw.githubusercontent.com/PostgREST/postgrest/v14.12/test/spec/fixtures/schema.sql#L2494
CREATE TABLE test.fav_numbers (
    num test.complex,
    person text
);

-- trash / trash_details: one-to-one relationship (trash_details.id references
-- trash.id) with a jsonb column. Used for related order on a one-to-one
-- relationship combined with a JSON arrow on the related column.
-- https://raw.githubusercontent.com/PostgREST/postgrest/v14.12/test/spec/fixtures/schema.sql#L3011
CREATE TABLE test.trash (
    id int primary key
);

-- https://raw.githubusercontent.com/PostgREST/postgrest/v14.12/test/spec/fixtures/schema.sql#L3015
CREATE TABLE test.trash_details (
    id int primary key references test.trash(id),
    jsonb_col jsonb
);

------------------------------------------------------------------------------
-- Data
------------------------------------------------------------------------------

-- items: 1..15
-- https://raw.githubusercontent.com/PostgREST/postgrest/v14.12/test/spec/fixtures/data.sql#L206
INSERT INTO test.items (id)
    SELECT generate_series(1, 15);

-- no_pk
-- https://raw.githubusercontent.com/PostgREST/postgrest/v14.12/test/spec/fixtures/data.sql#L280
INSERT INTO test.no_pk VALUES (NULL, NULL);
INSERT INTO test.no_pk VALUES ('1', '0');
INSERT INTO test.no_pk VALUES ('2', '0');

-- clients
-- https://raw.githubusercontent.com/PostgREST/postgrest/v14.12/test/spec/fixtures/data.sql#L89
INSERT INTO test.clients VALUES (1, 'Microsoft');
INSERT INTO test.clients VALUES (2, 'Apple');

-- projects (project 5 "Orphan" has a NULL client_id)
-- https://raw.githubusercontent.com/PostgREST/postgrest/v14.12/test/spec/fixtures/data.sql#L98
INSERT INTO test.projects VALUES (1, 'Windows 7', 1);
INSERT INTO test.projects VALUES (2, 'Windows 10', 1);
INSERT INTO test.projects VALUES (3, 'IOS', 2);
INSERT INTO test.projects VALUES (4, 'OSX', 2);
INSERT INTO test.projects VALUES (5, 'Orphan', NULL);

-- users
-- https://raw.githubusercontent.com/PostgREST/postgrest/v14.12/test/spec/fixtures/data.sql#L44
INSERT INTO test.users VALUES (1, 'Angela Martin');
INSERT INTO test.users VALUES (2, 'Michael Scott');
INSERT INTO test.users VALUES (3, 'Dwight Schrute');

-- tasks
-- https://raw.githubusercontent.com/PostgREST/postgrest/v14.12/test/spec/fixtures/data.sql#L110
INSERT INTO test.tasks VALUES (1, 'Design w7', 1);
INSERT INTO test.tasks VALUES (2, 'Code w7', 1);
INSERT INTO test.tasks VALUES (3, 'Design w10', 2);
INSERT INTO test.tasks VALUES (4, 'Code w10', 2);
INSERT INTO test.tasks VALUES (5, 'Design IOS', 3);
INSERT INTO test.tasks VALUES (6, 'Code IOS', 3);
INSERT INTO test.tasks VALUES (7, 'Design OSX', 4);
INSERT INTO test.tasks VALUES (8, 'Code OSX', 4);

-- users_tasks (m2m): user 1 (Angela) maps to tasks 1,2,3,4 plus task 1 again via user 3
-- https://raw.githubusercontent.com/PostgREST/postgrest/v14.12/test/spec/fixtures/data.sql#L125
INSERT INTO test.users_tasks VALUES (1, 1);
INSERT INTO test.users_tasks VALUES (1, 2);
INSERT INTO test.users_tasks VALUES (1, 3);
INSERT INTO test.users_tasks VALUES (1, 4);
INSERT INTO test.users_tasks VALUES (2, 5);
INSERT INTO test.users_tasks VALUES (2, 6);
INSERT INTO test.users_tasks VALUES (2, 7);
INSERT INTO test.users_tasks VALUES (3, 1);
INSERT INTO test.users_tasks VALUES (3, 5);

-- json_table
-- https://raw.githubusercontent.com/PostgREST/postgrest/v14.12/test/spec/fixtures/data.sql#L264
INSERT INTO test.json_table VALUES ('{"foo":{"bar":"baz"},"id":1}');
INSERT INTO test.json_table VALUES ('{"id":3}');
INSERT INTO test.json_table VALUES ('{"id":0}');

-- fav_numbers
-- https://raw.githubusercontent.com/PostgREST/postgrest/v14.12/test/spec/fixtures/data.sql#L739
INSERT INTO test.fav_numbers VALUES (ROW(0.5, 0.5), 'A'), (ROW(0.6, 0.6), 'B');

-- trash / trash_details
-- https://raw.githubusercontent.com/PostgREST/postgrest/v14.12/test/spec/fixtures/data.sql#L807
INSERT INTO test.trash(id) VALUES (1), (2), (3);
-- https://raw.githubusercontent.com/PostgREST/postgrest/v14.12/test/spec/fixtures/data.sql#L810
INSERT INTO test.trash_details(id, jsonb_col) VALUES (1, '{"key": 10}'), (2, '{"key": 6}'), (3, '{"key": 8}');
