-- Bier conformance fixtures: errors feature area
-- Mirrors a minimal subset of PostgREST v14.12 test/spec/fixtures/schema.sql
-- and data.sql needed by spec/conformance/cases/1500..1549.
--
-- Scope of this fixture: objects whose execution triggers a PostgreSQL
-- SQLSTATE that PostgREST maps to an HTTP status, plus the RAISE-based
-- custom-error functions (PTxxx and `RAISE SQLSTATE 'PGRST'`).
--
-- Source of truth (object shapes copied/condensed from upstream):
--   raise_pt402 / raise_bad_pt:
--     https://github.com/PostgREST/postgrest/blob/v14.12/test/spec/fixtures/schema.sql#L1289
--   raise_sqlstate_test1..4 / invalid / missing:
--     https://github.com/PostgREST/postgrest/blob/v14.12/test/spec/fixtures/schema.sql#L3312
--   problem() / assert():
--     https://github.com/PostgREST/postgrest/blob/v14.12/test/spec/fixtures/schema.sql#L408
--   simple_pk (unique_violation 23505):
--     https://github.com/PostgREST/postgrest/blob/v14.12/test/spec/fixtures/schema.sql#L769
--   simple_pk seed row 'xyyx':
--     https://github.com/PostgREST/postgrest/blob/v14.12/test/spec/fixtures/data.sql#L185
--
-- All objects live in schema `test` to match PostgREST's exposed schema.

create schema if not exists test;
set search_path = test, public;

-- ---------------------------------------------------------------------------
-- unique_violation (SQLSTATE 23505 -> HTTP 409)
-- A second insert of the same primary key triggers the violation.
-- schema.sql:769 ; data.sql:185
-- ---------------------------------------------------------------------------
create table test.simple_pk (
  k     varchar not null,
  extra varchar not null,
  primary key (k)
);
insert into test.simple_pk values ('xyyx', 'u');

-- ---------------------------------------------------------------------------
-- foreign_key_violation (SQLSTATE 23503 -> HTTP 409)
-- Inserting a child row referencing a missing parent triggers the violation.
-- (table_a / table_b shape mirrors schema.sql table_a/table_b)
-- schema.sql:3645
-- ---------------------------------------------------------------------------
create table test.fk_parent (
  id int primary key
);
create table test.fk_child (
  id        int primary key,
  parent_id int references test.fk_parent(id)
);

-- ---------------------------------------------------------------------------
-- PTxxx custom error: RAISE SQLSTATE 'PTnnn' maps to HTTP status nnn.
-- schema.sql:1289
-- ---------------------------------------------------------------------------
create or replace function test.raise_pt402() returns void as $$
begin
  raise sqlstate 'PT402' using message = 'Payment Required',
                               detail  = 'Quota exceeded',
                               hint    = 'Upgrade your plan';
end;
$$ language plpgsql;

-- PT followed by a non-numeric suffix -> defaults to HTTP 500.
-- schema.sql:1297
create or replace function test.raise_bad_pt() returns void as $$
begin
  raise sqlstate 'PT40A' using message = 'Wrong';
end;
$$ language plpgsql;

-- ---------------------------------------------------------------------------
-- RAISE SQLSTATE 'PGRST' custom error: full response control via JSON in the
-- MESSAGE (code/message/details/hint) and DETAIL (status/status_text/headers).
-- schema.sql:3312
-- ---------------------------------------------------------------------------
create or replace function test.raise_sqlstate_test1() returns void
  language plpgsql as $$
begin
  raise sqlstate 'PGRST' using
    message = '{"code":"123","message":"ABC","details":"DEF","hint":"XYZ"}',
    detail  = '{"status":332,"status_text":"My Custom Status","headers":{"X-Header":"str"}}';
end
$$;

-- Minimal MESSAGE (no details/hint) -> details/hint serialize as null.
-- schema.sql:3322
create or replace function test.raise_sqlstate_test2() returns void
  language plpgsql as $$
begin
  raise sqlstate 'PGRST' using
    message = '{"code":"123","message":"ABC"}',
    detail  = '{"status":332,"headers":{"X-Header":"str"}}';
end
$$;

-- status 404 with no status_text -> standard reason phrase "Not Found".
-- schema.sql:3332
create or replace function test.raise_sqlstate_test3() returns void
  language plpgsql as $$
begin
  raise sqlstate 'PGRST' using
    message = '{"code":"123","message":"ABC"}',
    detail  = '{"status":404,"headers":{"X-Header":"str"}}';
end
$$;

-- status 404 WITH custom status_text -> "My Not Found".
-- schema.sql:3342
create or replace function test.raise_sqlstate_test4() returns void
  language plpgsql as $$
begin
  raise sqlstate 'PGRST' using
    message = '{"code":"123","message":"ABC"}',
    detail  = '{"status":404,"status_text":"My Not Found","headers":{"X-Header":"str"}}';
end
$$;

-- MESSAGE is not valid JSON -> PGRST121 parse error (HTTP 500).
-- schema.sql:3352
create or replace function test.raise_sqlstate_invalid_json_message() returns void
  language plpgsql as $$
begin
  raise sqlstate 'PGRST' using
    message = 'INVALID',
    detail  = '{"status":332,"headers":{"X-Header":"str"}}';
end
$$;

-- DETAIL is not valid JSON -> PGRST121 parse error (HTTP 500).
-- schema.sql:3362
create or replace function test.raise_sqlstate_invalid_json_details() returns void
  language plpgsql as $$
begin
  raise sqlstate 'PGRST' using
    message = '{"code":"123","message":"ABC","details":"DEF"}',
    detail  = 'INVALID';
end
$$;

-- DETAIL missing entirely -> PGRST121 parse error (HTTP 500).
-- schema.sql:3372
create or replace function test.raise_sqlstate_missing_details() returns void
  language plpgsql as $$
begin
  raise sqlstate 'PGRST' using
    message = '{"code":"123","message":"ABC","details":"DEF"}';
end
$$;

-- ---------------------------------------------------------------------------
-- plpgsql RAISE with no explicit SQLSTATE -> default code P0001 -> HTTP 400.
-- schema.sql:421
-- ---------------------------------------------------------------------------
create or replace function test.problem() returns void
  language plpgsql as $$
begin
  raise 'bad thing';
end;
$$;

-- plpgsql ASSERT failure -> SQLSTATE P0004 (class P0) -> HTTP 500.
-- schema.sql:408
create or replace function test.assert() returns void
  language plpgsql as $$
begin
  assert false, 'bad thing';
end;
$$;

-- ---------------------------------------------------------------------------
-- cardinality_violation (SQLSTATE 21000) from a scalar subquery returning
-- more than one row -> generic server error HTTP 500.
-- (mirrors upstream `bad_subquery` view; schema.sql:3662)
-- ---------------------------------------------------------------------------
create table test.cv_rows (
  id int primary key
);
insert into test.cv_rows values (1), (2);

create view test.bad_subquery as
  select * from test.cv_rows where id = (select id from test.cv_rows);
