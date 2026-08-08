-- url_grammar area fixture delta (PostgREST v16.0 re-sync).
--
-- Write channel per spec/conformance/fixtures/README.md: NEW objects only.
-- The Fixture Consolidator folds this into ../fixtures.sql and then empties
-- this file. Do not add DDL that ../fixtures.sql already carries.
--
-- Added for case 1029 (url_grammar/reserved-characters/quoted-identifier):
-- a table whose column names contain every PostgREST reserved character
-- (`*`, `:`, `(`, `)`, `,`, `.`) plus leading/inner/trailing spaces, so the
-- `%22`-quoted-identifier rule of spec/url_grammar.md section 6.3 can be
-- exercised end to end. Mirrors PostgREST v16.0
-- test/spec/fixtures/schema.sql#L1821-L1827 (DDL) and
-- test/spec/fixtures/data.sql#L571-L576 (rows; upstream loads them with
-- `COPY ... FROM STDIN CSV DELIMITER '|'`, which yields the surrounding
-- spaces reproduced literally below).
--
-- `test.pgrst_reserved_chars` does not exist in ../fixtures.sql (verified with
-- `\d test.pgrst_reserved_chars` against a freshly loaded bier_test).

CREATE TABLE test.pgrst_reserved_chars (
  "*id*" integer,
  ":arr->ow::cast" text,
  "(inside,parens)" text,
  "a.dotted.column" text,
  "  col  w  space  " text
);

INSERT INTO test.pgrst_reserved_chars
  ("*id*", ":arr->ow::cast", "(inside,parens)", "a.dotted.column", "  col  w  space  ")
VALUES
  (1, ' arrow-1 ', ' parens-1 ', ' dotted-1 ', ' space-1'),
  (2, ' arrow-2 ', ' parens-2 ', ' dotted-2 ', ' space-2'),
  (3, ' arrow-3 ', ' parens-3 ', ' dotted-3 ', ' space-3');
