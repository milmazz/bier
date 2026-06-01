-- Conformance fixtures for the "select" feature area (PostgREST v14.12).
--
-- Self-contained subset of PostgREST's own test fixtures, restricted to the
-- tables/data exercised by spec/conformance/cases/1100..1149.
--
-- Sources (PostgREST v14.12 test/spec/fixtures):
--   schema.sql: complex_items L555, clients L546, projects L719, tasks L792,
--               users L781, users_tasks L809, items L126 + always_true L145,
--               entities L1167, child_entities L1174, json_arr L1548,
--               project_invoices L3582, students L2785, students_info L2792,
--               country L2800, capital L2805, designers L2735, videogames L2740,
--               computed_designers L2747, computed_videogames L2755
--   data.sql:   users L44, clients L89, projects L98, tasks L110,
--               users_tasks L125, complex_items L169, entities L357,
--               child_entities L363, json_arr L506, project_invoices L846,
--               designers L789, videogames L792, students L795,
--               students_info L798, country L801, capital L804
--
-- Loads into Postgres 14/15/16. PostgREST exposes schema "test" by default
-- (db-schemas = "test"); aggregate-function cases additionally require
-- db-aggregates-enabled = true.

DROP SCHEMA IF EXISTS test CASCADE;
CREATE SCHEMA test;
SET search_path = test, pg_catalog;

-- complex_items: columns, alias, ::cast, JSON column + JSON paths -----------
CREATE TABLE complex_items (
    id bigint NOT NULL PRIMARY KEY,
    name text,
    settings json,
    arr_data integer[],
    "field-with_sep" integer DEFAULT 1 NOT NULL
);
INSERT INTO complex_items VALUES (1, 'One',   '{"foo":{"int":1,"bar":"baz"}}', '{1}');
INSERT INTO complex_items VALUES (2, 'Two',   '{"foo":{"int":1,"bar":"baz"}}', '{1,2}');
INSERT INTO complex_items VALUES (3, 'Three', '{"foo":{"int":1,"bar":"baz"}}', '{1,2,3}', 3);

-- json_arr: JSON array index paths ------------------------------------------
CREATE TABLE json_arr (
    id integer PRIMARY KEY,
    data json
);
INSERT INTO json_arr VALUES (1, '[1, 2, 3]');
INSERT INTO json_arr VALUES (2, '[4, 5, 6]');

-- clients / projects: many-to-one (projects -> clients) ---------------------
CREATE TABLE clients (
    id integer PRIMARY KEY,
    name text NOT NULL
);
INSERT INTO clients VALUES (1, 'Microsoft');
INSERT INTO clients VALUES (2, 'Apple');

CREATE TABLE projects (
    id integer PRIMARY KEY,
    name text NOT NULL,
    client_id integer REFERENCES clients(id)
);
-- PostgREST renames this FK constraint to "client" (used as a hint).
ALTER TABLE projects RENAME CONSTRAINT projects_client_id_fkey TO client;
INSERT INTO projects VALUES (1, 'Windows 7',  1);
INSERT INTO projects VALUES (2, 'Windows 10', 1);
INSERT INTO projects VALUES (3, 'IOS',        2);
INSERT INTO projects VALUES (4, 'OSX',        2);
INSERT INTO projects VALUES (5, 'Orphan',     NULL);

-- tasks: one-to-many child of projects --------------------------------------
CREATE TABLE tasks (
    id integer PRIMARY KEY,
    name text NOT NULL,
    project_id integer REFERENCES projects(id)
);
INSERT INTO tasks VALUES (1, 'Design w7',  1);
INSERT INTO tasks VALUES (2, 'Code w7',    1);
INSERT INTO tasks VALUES (3, 'Design w10', 2);
INSERT INTO tasks VALUES (4, 'Code w10',   2);
INSERT INTO tasks VALUES (5, 'Design IOS', 3);
INSERT INTO tasks VALUES (6, 'Code IOS',   3);
INSERT INTO tasks VALUES (7, 'Design OSX', 4);
INSERT INTO tasks VALUES (8, 'Code OSX',   4);

-- users + users_tasks: many-to-many users <-> tasks via junction ------------
CREATE TABLE users (
    id integer PRIMARY KEY,
    name text NOT NULL
);
INSERT INTO users VALUES (1, 'Angela Martin');
INSERT INTO users VALUES (2, 'Michael Scott');
INSERT INTO users VALUES (3, 'Dwight Schrute');

CREATE TABLE users_tasks (
    user_id integer NOT NULL REFERENCES users(id),
    task_id integer NOT NULL REFERENCES tasks(id),
    PRIMARY KEY (task_id, user_id)
);
INSERT INTO users_tasks VALUES (1, 1);
INSERT INTO users_tasks VALUES (1, 2);
INSERT INTO users_tasks VALUES (1, 3);
INSERT INTO users_tasks VALUES (1, 4);
INSERT INTO users_tasks VALUES (2, 5);
INSERT INTO users_tasks VALUES (2, 6);
INSERT INTO users_tasks VALUES (2, 7);
INSERT INTO users_tasks VALUES (3, 1);
INSERT INTO users_tasks VALUES (3, 5);

-- items + computed column always_true --------------------------------------
CREATE TABLE items (
    id bigserial PRIMARY KEY
);
INSERT INTO items (id) SELECT generate_series(1, 15);

CREATE FUNCTION always_true(test.items) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    AS $$ SELECT true $$;

-- entities / child_entities: one-to-many for !inner / !left -----------------
CREATE TABLE entities (
    id integer PRIMARY KEY,
    name text,
    arr integer[],
    text_search_vector tsvector
);
INSERT INTO entities VALUES (1, 'entity 1', '{1}',     NULL);
INSERT INTO entities VALUES (2, 'entity 2', '{1,2}',   NULL);
INSERT INTO entities VALUES (3, 'entity 3', '{1,2,3}', NULL);
INSERT INTO entities VALUES (4, NULL,       NULL,      NULL);

CREATE TABLE child_entities (
    id integer PRIMARY KEY,
    name text,
    parent_id integer REFERENCES entities(id)
);
INSERT INTO child_entities VALUES (1, 'child entity 1', 1);
INSERT INTO child_entities VALUES (2, 'child entity 2', 1);
INSERT INTO child_entities VALUES (3, 'child entity 3', 2);
INSERT INTO child_entities VALUES (4, 'child entity 4', 1);
INSERT INTO child_entities VALUES (5, 'child entity 5', 1);
INSERT INTO child_entities VALUES (6, 'child entity 6', 2);

-- project_invoices: aggregate functions ------------------------------------
CREATE TABLE project_invoices (
    id int PRIMARY KEY,
    invoice_total numeric,
    project_id integer REFERENCES projects(id)
);
INSERT INTO project_invoices VALUES (1, 100,  1);
INSERT INTO project_invoices VALUES (2, 200,  1);
INSERT INTO project_invoices VALUES (3, 500,  2);
INSERT INTO project_invoices VALUES (4, 700,  2);
INSERT INTO project_invoices VALUES (5, 1200, 3);
INSERT INTO project_invoices VALUES (6, 2000, 3);
INSERT INTO project_invoices VALUES (7, 100,  4);
INSERT INTO project_invoices VALUES (8, 4000, 4);

-- sites / big_projects / jobs: ambiguous embed (PGRST201 / 300) ------------
-- Produces exactly three candidate relationships between sites and
-- big_projects: main_project (m2o), jobs (m2m), main_jobs (m2m).
-- schema.sql L1943-L1965.
CREATE TABLE big_projects (
    big_project_id serial PRIMARY KEY,
    name text
);

CREATE TABLE sites (
    site_id serial PRIMARY KEY,
    name text,
    main_project_id int NULL REFERENCES big_projects(big_project_id)
);
ALTER TABLE sites RENAME CONSTRAINT sites_main_project_id_fkey TO main_project;

CREATE TABLE jobs (
    job_id uuid,
    name text,
    site_id int NOT NULL REFERENCES sites(site_id),
    big_project_id int NOT NULL REFERENCES big_projects(big_project_id),
    PRIMARY KEY (job_id, site_id, big_project_id)
);

CREATE VIEW main_jobs AS
    SELECT * FROM jobs
    WHERE site_id IN (SELECT site_id FROM sites WHERE main_project_id IS NOT NULL);

-- students / students_info: one-to-one via pk-as-fk -------------------------
-- students_info shares its (id, code) primary key with students and also uses
-- it as the FK, so the relationship is one-to-one (a single object embed).
-- schema.sql L2785-L2798; data.sql L795, L798.
CREATE TABLE students (
    id integer,
    code text,
    name text,
    PRIMARY KEY (id, code)
);
INSERT INTO students (id, code, name) VALUES (1, '0001', 'John Doe'), (2, '0002', 'Jane Doe');

CREATE TABLE students_info (
    id integer,
    code text,
    address text,
    PRIMARY KEY (id, code),
    FOREIGN KEY (code, id) REFERENCES students(code, id) ON DELETE CASCADE
);
INSERT INTO students_info (id, code, address) VALUES (1, '0001', 'Street 1'), (2, '0002', 'Street 2');

-- country / capital: one-to-one via a UNIQUE-constraint FK ------------------
-- capital.country_id is a UNIQUE FK to country, so each country has at most one
-- capital; embedding either side yields a single object.
-- schema.sql L2800-L2810; data.sql L801, L804.
CREATE TABLE country (
    id integer PRIMARY KEY,
    name text
);
INSERT INTO country (id, name) VALUES (1, 'Afghanistan'), (2, 'Algeria');

CREATE TABLE capital (
    id integer PRIMARY KEY,
    name text,
    country_id integer UNIQUE,
    FOREIGN KEY (country_id) REFERENCES country(id)
);
INSERT INTO capital (id, name, country_id) VALUES (1, 'Kabul', 1), (2, 'Algiers', 2);

-- designers / videogames + computed relationships ---------------------------
-- computed_designers is a SETOF-returning function on the videogames row type
-- that defines a many-to-one relationship; computed_videogames defines the
-- inverse one-to-many. (designers.name uses a titlecasetext domain upstream;
-- simplified to text here since no data-representation behavior is asserted by
-- the cited L15/L43 tests.)
-- schema.sql L2735-L2757; data.sql L789, L792.
CREATE TABLE designers (
    id integer PRIMARY KEY,
    name text
);
INSERT INTO designers (id, name) VALUES (1, 'Sid Meier'), (2, 'Hironobu Sakaguchi');

CREATE TABLE videogames (
    id integer PRIMARY KEY,
    name text,
    designer_id integer REFERENCES designers(id)
);
INSERT INTO videogames (id, name, designer_id) VALUES
    (1, 'Civilization I',  1),
    (2, 'Civilization II', 1),
    (3, 'Final Fantasy I',  2),
    (4, 'Final Fantasy II', 2);

CREATE FUNCTION computed_designers(test.videogames) RETURNS SETOF test.designers
    LANGUAGE sql STABLE ROWS 1
    AS $$ SELECT * FROM test.designers WHERE id = $1.designer_id $$;

CREATE FUNCTION computed_videogames(test.designers) RETURNS SETOF test.videogames
    LANGUAGE sql STABLE
    AS $$ SELECT * FROM test.videogames WHERE designer_id = $1.id $$;
