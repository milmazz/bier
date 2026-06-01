-- Conformance fixtures for the "operators" feature area (PostgREST v14.12).
--
-- All table shapes and row data are copied verbatim from PostgREST's own
-- test fixtures so the expected response bodies in the conformance cases
-- match byte-for-byte:
--   schema: test/spec/fixtures/schema.sql
--   data:   test/spec/fixtures/data.sql
-- See each block's source comment for the upstream line anchor.
--
-- Loads cleanly into Postgres 14/15/16.

-- ---------------------------------------------------------------------------
-- items  (schema.sql:126 ; data.sql:205)
-- ---------------------------------------------------------------------------
CREATE TABLE items (
    id bigserial primary key
);
INSERT INTO items VALUES
  (1),(2),(3),(4),(5),(6),(7),(8),(9),(10),(11),(12),(13),(14),(15);

-- ---------------------------------------------------------------------------
-- simple_pk  (schema.sql:769 ; data.sql:184)
-- ---------------------------------------------------------------------------
CREATE TABLE simple_pk (
    PRIMARY KEY (k),
    k character varying NOT NULL,
    extra character varying NOT NULL
);
INSERT INTO simple_pk VALUES ('xyyx', 'u');
INSERT INTO simple_pk VALUES ('xYYx', 'v');

-- ---------------------------------------------------------------------------
-- no_pk  (schema.sql:688 ; data.sql:279)
-- ---------------------------------------------------------------------------
CREATE TABLE no_pk (
    a character varying,
    b character varying
);
INSERT INTO no_pk VALUES (NULL, NULL);
INSERT INTO no_pk VALUES ('1', '0');
INSERT INTO no_pk VALUES ('2', '0');

-- ---------------------------------------------------------------------------
-- nullable_integer  (schema.sql:701 ; data.sql:289)
-- ---------------------------------------------------------------------------
CREATE TABLE nullable_integer (
    a integer
);
INSERT INTO nullable_integer VALUES (NULL);

-- ---------------------------------------------------------------------------
-- chores  (schema.sql:2457 ; data.sql:735)
-- ---------------------------------------------------------------------------
CREATE TABLE chores (
  id int primary key
, name text
, done bool
);
INSERT INTO chores (id, name, done) values
  (1, 'take out the garbage', true),
  (2, 'do the laundry', false),
  (3, 'wash the dishes', null);

-- ---------------------------------------------------------------------------
-- complex_items  (schema.sql:555 ; data.sql:168)
-- ---------------------------------------------------------------------------
CREATE TABLE complex_items (
    id bigint NOT NULL primary key,
    name text,
    settings json,
    arr_data integer[],
    "field-with_sep" integer default 1 not null
);
INSERT INTO complex_items VALUES (1, 'One', '{"foo":{"int":1,"bar":"baz"}}', '{1}');
INSERT INTO complex_items VALUES (2, 'Two', '{"foo":{"int":1,"bar":"baz"}}', '{1,2}');
INSERT INTO complex_items VALUES (3, 'Three', '{"foo":{"int":1,"bar":"baz"}}', '{1,2,3}', 3);

-- ---------------------------------------------------------------------------
-- projects  (schema.sql:719 ; data.sql:97)
-- NOTE: upstream references clients(id); we make client_id a plain integer
-- here because no operator case embeds clients. Rows are identical.
-- ---------------------------------------------------------------------------
CREATE TABLE projects (
    id integer primary key,
    name text NOT NULL,
    client_id integer
);
INSERT INTO projects VALUES (1, 'Windows 7', 1);
INSERT INTO projects VALUES (2, 'Windows 10', 1);
INSERT INTO projects VALUES (3, 'IOS', 2);
INSERT INTO projects VALUES (4, 'OSX', 2);
INSERT INTO projects VALUES (5, 'Orphan', NULL);

-- ---------------------------------------------------------------------------
-- articles  (schema.sql:843 private.articles ; data.sql:31)
-- Exposed as /articles. owner column kept for fidelity.
-- ---------------------------------------------------------------------------
CREATE TABLE articles (
    id integer primary key,
    body text,
    owner name not null
);
INSERT INTO articles VALUES (1, 'No… It''s a thing; it''s like a plan, but with more greatness.', 'diogo');
INSERT INTO articles VALUES (2, 'Stop talking, brain thinking. Hush.', 'diogo');
INSERT INTO articles VALUES (3, 'It''s a fez. I wear a fez now. Fezes are cool.', 'diogo');

-- ---------------------------------------------------------------------------
-- tsearch  (schema.sql:878 ; data.sql:297)
-- ---------------------------------------------------------------------------
CREATE TABLE tsearch (
    text_search_vector tsvector
);
INSERT INTO tsearch VALUES (to_tsvector('It''s kind of fun to do the impossible'));
INSERT INTO tsearch VALUES (to_tsvector('But also fun to do what is possible'));
INSERT INTO tsearch VALUES (to_tsvector('Fat cats ate rats'));
INSERT INTO tsearch VALUES (to_tsvector('french', 'C''est un peu amusant de faire l''impossible'));
INSERT INTO tsearch VALUES (to_tsvector('german', 'Es ist eine Art Spaß, das Unmögliche zu machen'));

-- ---------------------------------------------------------------------------
-- entities  (schema.sql:1167 ; data.sql:356)
-- ---------------------------------------------------------------------------
CREATE TABLE entities (
  id integer primary key,
  name text,
  arr integer[],
  text_search_vector tsvector
);
INSERT INTO entities VALUES (1, 'entity 1', '{1}', '''bar'':2 ''foo'':1');
INSERT INTO entities VALUES (2, 'entity 2', '{1,2}', '''baz'':1 ''qux'':2');
INSERT INTO entities VALUES (3, 'entity 3', '{1,2,3}', null);
INSERT INTO entities VALUES (4, null, null, null);

-- ---------------------------------------------------------------------------
-- ranges  (schema.sql:1193 ; data.sql:377)
-- ---------------------------------------------------------------------------
CREATE TABLE ranges (
    id integer primary key,
    range numrange
);
INSERT INTO ranges VALUES (1, '[1,3]');
INSERT INTO ranges VALUES (2, '[3,6]');
INSERT INTO ranges VALUES (3, '[6,9]');
INSERT INTO ranges VALUES (4, '[9,12]');
INSERT INTO ranges VALUES (5, null);
