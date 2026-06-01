-- Fixture for the url_grammar conformance area.
--
-- Mirrors the subset of PostgREST's own test fixtures that the url_grammar
-- cases exercise:
--   * a simple table with a primary key (path -> table -> row resolution)
--     modelled on PostgREST's `test.items`
--     (postgrest v14.12 test/spec/fixtures/schema.sql#L126)
--   * a unicode schema + table (percent-encoded path resolution)
--     modelled on PostgREST's `تست.موارد`
--     (postgrest v14.12 test/spec/fixtures/schema.sql#L186)
--   * two versioned schemas v1/v2 for Accept-Profile / Content-Profile
--     negotiation, modelled on PostgREST's v1/v2 fixtures
--     (postgrest v14.12 test/spec/fixtures/schema.sql#L2112)
--
-- Exposed schemas for these cases (PostgREST `db-schemas`):
--   default single-schema cases:  ["test"]              (PostgREST testCfg)
--   unicode case:                 ["تست"]               (PostgREST testUnicodeCfg)
--   multi-schema cases:           ["v1","v2"]           (PostgREST testMultipleSchemaCfg)
-- The conformance runner selects the schema set via the case `schema` field.

CREATE SCHEMA IF NOT EXISTS test;
CREATE SCHEMA IF NOT EXISTS "تست";
CREATE SCHEMA IF NOT EXISTS v1;
CREATE SCHEMA IF NOT EXISTS v2;

-- ----------------------------------------------------------------------------
-- schema: test  (single-schema, default profile)
-- ----------------------------------------------------------------------------

CREATE TABLE test.items (
    id bigserial primary key
);

INSERT INTO test.items (id) VALUES
  (1),(2),(3),(4),(5),(6),(7),(8),(9),(10),
  (11),(12),(13),(14),(15);

-- Names that contain PostgREST reserved characters (notably the comma `,`).
-- Used by the reserved-character-quoting cases: a filter value carrying a
-- reserved char must be wrapped in double quotes (percent-encoded as %22) so
-- the comma is read as part of the value, not as an `in.(a,b)` separator.
-- Mirrors PostgREST's `w_or_wo_comma_names` fixture
--   table:  postgrest v14.12 test/spec/fixtures/schema.sql#L1152
--   data:   postgrest v14.12 test/spec/fixtures/data.sql#L342-L351
CREATE TABLE test.w_or_wo_comma_names (
    name text
);

INSERT INTO test.w_or_wo_comma_names (name) VALUES
  ('Hebdon, John'),
  ('Williams, Mary'),
  ('Smith, Joseph'),
  ('David White'),
  ('Larry Thompson'),
  ('Double O Seven(007)');

-- ----------------------------------------------------------------------------
-- schema: تست  (unicode names; reached via percent-encoded path)
-- ----------------------------------------------------------------------------

CREATE TABLE "تست"."موارد" (
    "هویت" bigint NOT NULL
);

-- ----------------------------------------------------------------------------
-- schemas: v1 / v2  (profile negotiation)
-- ----------------------------------------------------------------------------

CREATE TABLE v1.parents (
    id   int primary key,
    name text
);

INSERT INTO v1.parents (id, name) VALUES
  (1, 'parent v1-1'),
  (2, 'parent v1-2');

-- children with a FK to parents; used to assert Content-Profile (write) schema
-- selection and embedding within the chosen profile
-- (postgrest v14.12 test/spec/fixtures/schema.sql#L2117)
CREATE TABLE v1.children (
    id        int primary key,
    name      text,
    parent_id int,
    CONSTRAINT parent FOREIGN KEY (parent_id) REFERENCES v1.parents(id)
);

INSERT INTO v1.children (id, name, parent_id) VALUES
  (1, 'child v1-1', 1),
  (2, 'child v1-2', 2);

-- RPC reachable via /rpc/get_parents_below in the v1 schema
-- (postgrest v14.12 test/spec/fixtures/schema.sql#L2125)
CREATE FUNCTION v1.get_parents_below(id int)
RETURNS setof v1.parents AS $$
  SELECT * FROM v1.parents WHERE id < $1;
$$ LANGUAGE sql;

CREATE TABLE v2.parents (
    id   int primary key,
    name text
);

INSERT INTO v2.parents (id, name) VALUES
  (3, 'parent v2-3'),
  (4, 'parent v2-4');

-- v2.children mirrors v1.children but in the v2 schema; the same /children path
-- resolves here when Content-Profile/Accept-Profile selects v2
-- (postgrest v14.12 test/spec/fixtures/schema.sql#L2135)
CREATE TABLE v2.children (
    id        int primary key,
    name      text,
    parent_id int,
    CONSTRAINT parent FOREIGN KEY (parent_id) REFERENCES v2.parents(id)
);

INSERT INTO v2.children (id, name, parent_id) VALUES
  (1, 'child v2-3', 3);

-- same-named RPC in v2 (asserts per-schema routine resolution)
CREATE FUNCTION v2.get_parents_below(id int)
RETURNS setof v2.parents AS $$
  SELECT * FROM v2.parents WHERE id < $1;
$$ LANGUAGE sql;

-- another_table exists only in v2 (used to assert per-schema resolution)
CREATE TABLE v2.another_table (
    id            int primary key,
    another_value text
);

INSERT INTO v2.another_table (id, another_value) VALUES
  (5, 'value 5'),
  (6, 'value 6');
