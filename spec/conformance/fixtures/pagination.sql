-- Pagination conformance fixture for Bier (PostgREST v14.12 parity)
--
-- Self-contained schema + data extracted from PostgREST's own test fixtures so
-- the pagination/limit/offset/Range/Content-Range/count conformance cases can
-- run against an identical dataset.
--
-- Sources (PostgREST v14.12):
--   test/spec/fixtures/schema.sql  (table/function/view definitions)
--     - items table:            schema.sql#L126-L128
--     - getitemrange function:  schema.sql#L214-L219
--     - clients table:          schema.sql#L546-L549
--     - menagerie table:        schema.sql#L673-L681
--     - projects table:         schema.sql#L719-L723
--     - users table:            schema.sql#L781-L784
--     - tasks table:            schema.sql#L792-L796
--     - users_tasks table:      schema.sql#L809-L813
--     - entities table:         schema.sql#L1167-L1172
--     - child_entities table:   schema.sql#L1174-L1178
--     - get_projects_above fn:  schema.sql#L1031-L1035 (ROWS 1)
--     - getallprojects fn:      schema.sql#L1037-L1041 (ROWS 2019)
--     - getallprojects_view:    schema.sql#L1906-L1907
--     - get_projects_above_view: schema.sql#L1909-L1910
--   test/spec/fixtures/data.sql   (row data)
--     - items 1..15:            data.sql#L206-L220
--     - users 1..3:             data.sql#L44-L46
--     - clients 1..2:           data.sql#L89-L90
--     - projects 1..5:          data.sql#L98-L102
--     - tasks 1..8:             data.sql#L110-L117
--     - users_tasks:            data.sql#L125-L133
--     - entities 1..4:          data.sql#L357-L360
--     - child_entities 1..6:    data.sql#L363-L368
--
-- NOTE on planned/estimated counts: count=planned and count=estimated rely on
-- the PostgreSQL query planner's row estimate (EXPLAIN). For SETOF functions,
-- the planner uses the function's ROWS declaration (getallprojects() = 2019,
-- get_projects_above() = 1). These estimates are planner-dependent and may vary
-- across PG versions / after ANALYZE. The conformance cases that assert a
-- specific planned/estimated total carry a notes caveat to that effect.

BEGIN;

CREATE SCHEMA IF NOT EXISTS test;
SET search_path = test, public;

-- ---------------------------------------------------------------------------
-- items: 15 rows, single bigserial id column.
-- ---------------------------------------------------------------------------
CREATE TABLE test.items (
    id bigserial primary key
);

INSERT INTO test.items (id)
SELECT g FROM generate_series(1, 15) AS g;
SELECT pg_catalog.setval('test.items_id_seq', 15, true);

-- getitemrange(min, max): SETOF items WHERE id > min AND id <= max
CREATE FUNCTION test.getitemrange(min bigint, max bigint) RETURNS SETOF test.items
    LANGUAGE sql
    STABLE
    AS $_$
    SELECT * FROM test.items WHERE id > $1 AND id <= $2;
$_$;

-- ---------------------------------------------------------------------------
-- menagerie: empty in this fixture (used to assert count over an empty table).
-- The pagination cases only need it to be empty, so we omit the wide column set
-- of the upstream fixture and keep a minimal compatible shape.
-- ---------------------------------------------------------------------------
CREATE TABLE test.menagerie (
    "integer" integer NOT NULL PRIMARY KEY
);
-- intentionally no rows

-- ---------------------------------------------------------------------------
-- clients / projects / tasks / users for nested (per-level) limit/offset.
-- ---------------------------------------------------------------------------
CREATE TABLE test.clients (
    id integer primary key,
    name text NOT NULL
);
INSERT INTO test.clients VALUES (1, 'Microsoft'), (2, 'Apple');

CREATE TABLE test.projects (
    id integer primary key,
    name text NOT NULL,
    client_id integer REFERENCES test.clients(id)
);
INSERT INTO test.projects VALUES
    (1, 'Windows 7', 1),
    (2, 'Windows 10', 1),
    (3, 'IOS', 2),
    (4, 'OSX', 2),
    (5, 'Orphan', NULL);

CREATE TABLE test.users (
    id integer primary key,
    name text NOT NULL
);
INSERT INTO test.users VALUES
    (1, 'Angela Martin'),
    (2, 'Michael Scott'),
    (3, 'Dwight Schrute');

CREATE TABLE test.tasks (
    id integer primary key,
    name text NOT NULL,
    project_id integer REFERENCES test.projects(id)
);
INSERT INTO test.tasks VALUES
    (1, 'Design w7', 1),
    (2, 'Code w7', 1),
    (3, 'Design w10', 2),
    (4, 'Code w10', 2),
    (5, 'Design IOS', 3),
    (6, 'Code IOS', 3),
    (7, 'Design OSX', 4),
    (8, 'Code OSX', 4);

-- many-to-many users <-> tasks (needed for /users?select=id,tasks(id))
CREATE TABLE test.users_tasks (
    user_id integer NOT NULL REFERENCES test.users(id),
    task_id integer NOT NULL REFERENCES test.tasks(id),
    PRIMARY KEY (task_id, user_id)
);
INSERT INTO test.users_tasks VALUES
    (1, 1), (1, 2), (1, 3), (1, 4),
    (2, 5), (2, 6), (2, 7),
    (3, 1), (3, 5);

-- ---------------------------------------------------------------------------
-- entities / child_entities for the count=planned two-level + filtered cases.
-- child_entities has 6 rows.
-- ---------------------------------------------------------------------------
CREATE TABLE test.entities (
    id integer primary key,
    name text,
    arr integer[]
);
INSERT INTO test.entities VALUES
    (1, 'entity 1', '{1}'),
    (2, 'entity 2', '{1,2}'),
    (3, 'entity 3', '{1,2,3}'),
    (4, null, null);

CREATE TABLE test.child_entities (
    id integer primary key,
    name text,
    parent_id integer REFERENCES test.entities(id)
);
INSERT INTO test.child_entities VALUES
    (1, 'child entity 1', 1),
    (2, 'child entity 2', 1),
    (3, 'child entity 3', 2),
    (4, 'child entity 4', 1),
    (5, 'child entity 5', 1),
    (6, 'child entity 6', 2);

-- ---------------------------------------------------------------------------
-- SETOF functions + views used by count=planned / count=estimated cases.
-- The ROWS declaration drives the planner estimate that count=planned returns.
-- ---------------------------------------------------------------------------
CREATE FUNCTION test.get_projects_above(id int) RETURNS SETOF test.projects
    LANGUAGE sql
    AS $_$
    SELECT * FROM test.projects WHERE id > $1;
$_$ ROWS 1;

CREATE FUNCTION test.getallprojects() RETURNS SETOF test.projects
    LANGUAGE sql
    AS $_$
    SELECT * FROM test.projects;
$_$ ROWS 2019;

CREATE VIEW test.getallprojects_view AS
    SELECT * FROM test.getallprojects();

CREATE VIEW test.get_projects_above_view AS
    SELECT * FROM test.get_projects_above(1);

COMMIT;
