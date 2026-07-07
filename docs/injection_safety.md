# Injection safety

How user-controlled input reaches SQL. Every request produces a single
parameterized statement, and almost every user value travels as a bound
parameter — but not all of them *can*. This page consolidates the
typed-literal binding strategy that is otherwise commented at each site
(`Bier.QueryExecutor.bind/3`, `Bier.Rpc`'s `call_arg/2`, and the SQL builders
in `Bier.Mutation`), so security reviewers can audit the model in one place.

## The rule

A user value is rendered in exactly one of two ways:

| Rendering | When | Where |
| --- | --- | --- |
| Bound parameter `$n` | The value's type is unconstrained (`nil`/`:text`): text comparisons, `like`/`ilike`, regex matches, full-text query strings, raw RPC bodies, whole mutation payloads | `QueryExecutor.bind/3` (first clause), `Rpc` variadic/octet args, `Mutation` payload binding |
| Escaped typed literal `'<escaped>'::<type>` | The value must carry a Postgres type the parameter protocol cannot supply | `QueryExecutor.bind/3` (second clause), `Rpc`'s `call_arg/2` scalar clause |

Nothing else of a request's *values* is ever interpolated. `limit`/`offset`
are integers produced by the query parser; JSON-path array indices are
interpolated only after matching `^-?\d+$` (`pg_literal_or_index/1`).

## Why a literal at all

PostgreSQL coerces text into ranges, arrays, and other structured types only
from an *unknown*-typed literal. A bound parameter arrives already typed as
`text`, and `text` does not implicitly convert to `int4range`, `tsrange`,
typed arrays, and friends — so `col && $1` with a text parameter fails where
`col && '[1,5)'::int4range` succeeds. The contexts that need this:

* **Ranges and arrays** — the structural operators (`cs`, `cd`, `ov`, `sl`,
  `sr`, `nxr`, `nxl`, `adj`) cast the value to the introspected column type.
* **Typed comparisons** — `eq`/`gt`/… against a non-text column, `isdistinct`,
  and the `any`/`all` quantifier forms, which build `'{…}'::<coltype>[]`.
* **RPC arguments** — a function call argument must coerce to the declared
  argument type; `call_arg/2` inlines `'<escaped>'::<argtype>` for scalars
  (the full-text-search language modifier gets the same treatment, as
  `'<escaped>'::regconfig`).

In each case the *value* is passed through `QueryExecutor.pg_literal/1`, which
wraps it in single quotes and doubles every embedded `'`. Under
`standard_conforming_strings` (the server default since PostgreSQL 9.1, never
disabled by Bier) backslash has no escape meaning inside a `'…'` literal, so
quote-doubling is a complete escape: no value can terminate the literal.
Only the cast after it is templated — see below.

## What constrains the cast: `quote_type/1`

The `::type` suffix is not user text either. `QueryExecutor.quote_type/1`
validates every cast against a conservative charset:

```elixir
~r/^[A-Za-z0-9_ \[\]\".]+$/
```

anything else throws `{:bad_request, :bad_cast}` (HTTP 400). The charset
admits schema-qualified, quoted, spaced, and array type names
(`"my schema".mytype[]`, `timestamp with time zone`) but excludes `'`, `(`,
`)`, `;`, `,` and `-` — a cast can neither re-open a string, call a function,
terminate the statement, nor start a comment. It guards both trusted and
untrusted type sources:

* the explicit `select=col::cast` from the query string (untrusted);
* introspected column types reaching `bind/3` and `Mutation`'s `type_cast/1`
  (trusted output of `format_type`, constrained anyway).

The one cast site that bypasses `quote_type/1` is `Rpc`'s `call_arg/2`, whose
types come verbatim from `pg_proc` introspection — never from the request.
(The set-returning RPC path routes its arguments through
`QueryExecutor.bind/3` and is therefore covered.)

## Site-by-site

**`QueryExecutor.bind/3`** — the single funnel for read-path filter values.
`nil`/`:text` types bind `$n`; everything else emits the escaped typed
literal. `bind_filter_value/3` picks the type from the introspected column
(or the JSON-path arrow: `->>` is `:text`, `->` is `jsonb`), and `in` lists
bind each element individually. Domain columns with a `text` data
representation bind `$n` and parse it through the domain's cast function.

**`Rpc`, `call_arg/2`** — variadic arguments and raw (octet-stream) bodies
bind `$n::type`; named scalar arguments inline `'<escaped>'::<argtype>` so
Postgres coerces from an unknown literal. Argument names are rendered with
`"name" => …` keyword-call syntax through identifier quoting.

**`Bier.Mutation`** (`insert_sql`/`upsert_sql`/`set_clause`/`where_clause`) —
payload *values* never appear in the SQL text at all: the whole JSON body is
encoded and bound as one `$1::text::jsonb` parameter, and each target column
is extracted per row by `extract_expr/4` as `(_e ->> '<col>')::<type>`
(`->` without a cast for `json`/`jsonb` columns; the write-representation
cast function for domains). The extraction key goes through `pg_literal/1`
and the cast through `quote_type/1`. `where_clause/3` reuses
`QueryExecutor.render_node/2`, so mutation filters follow the read-path rules
above. The only verbatim interpolation is the column DEFAULT used by
`missing=default` — taken from `pg_catalog`, not the request.

## Identifiers

Every identifier — schema, relation, column, alias, RPC argument name, the
`SET LOCAL ROLE` role — is rendered through `QueryExecutor.quote_ident/1`
(`"` doubled, wrapped in `"…"`), including names that were validated against
the schema cache anyway. Request GUCs (`request.jwt.claims`, headers,
cookies, …) are set via parameterized `set_config($1, $2, true)` calls.

## Future work

Because every untrusted value funnels through `bind/3`, `call_arg/2`, or the
bound-jsonb mutation payload, a property/fuzz test can target the model
directly: generate adversarial filter values (quotes, casts, `)`/`;`
splices) across operators and assert the built SQL parameterizes or escapes
them — anchoring this document in CI rather than in review.
