-- Fixtures for the "representations" feature area (Prefer: return=...).
-- Derived from PostgREST v14.12 test/spec/fixtures/schema.sql.
-- Tables are a minimal subset sufficient for the cases in
-- spec/conformance/cases/13xx_*.yaml.
--
-- Source anchors:
--   items:                schema.sql#L126
--   clients:              schema.sql#L546
--   complex_items:        schema.sql#L555
--   projects:             schema.sql#L719
--   auto_incrementing_pk: schema.sql#L515

CREATE SCHEMA IF NOT EXISTS test;
SET search_path = test, public;

-- items: single bigserial PK. Used for PATCH/DELETE return cases.
CREATE TABLE items (
    id bigserial primary key
);
INSERT INTO items (id) VALUES (1), (2), (3);
SELECT setval('items_id_seq', 3);

-- clients + projects: FK relationship for POST insert representation cases.
CREATE TABLE clients (
    id integer primary key,
    name text NOT NULL
);
INSERT INTO clients (id, name) VALUES (1, 'Microsoft'), (2, 'Apple');

CREATE TABLE projects (
    id integer primary key,
    name text NOT NULL,
    client_id integer REFERENCES clients(id)
);
INSERT INTO projects (id, name, client_id) VALUES
  (1, 'Windows 7', 1),
  (2, 'Windows 10', 1),
  (3, 'IOS', 2);

-- complex_items: used for DELETE return=representation shaping.
CREATE TABLE complex_items (
    id bigint NOT NULL primary key,
    name text,
    settings json,
    arr_data integer[],
    "field-with_sep" integer default 1 not null
);
INSERT INTO complex_items (id, name) VALUES (1, 'One'), (2, 'Two'), (3, 'Three');

-- auto_incrementing_pk: used for POST return=headers-only Location header.
CREATE TABLE auto_incrementing_pk (
    id serial primary key,
    nullable_string character varying,
    non_nullable_string character varying NOT NULL,
    inserted_at timestamp with time zone DEFAULT now()
);
