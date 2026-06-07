# QueryParser backend benchmark: regex/string vs `nimble_parsec`

Performance exploration for `Bier.QueryParser`'s **request-pipeline leaf
grammars**. An alternative `nimble_parsec` implementation
(`Bier.QueryParser.Nimble`) was built to be **drop-in behavior-identical** with
the existing regex/string path, then proved equivalent against the full
conformance suite and benchmarked function-by-function.

> TL;DR: the `nimble_parsec` backend is **1.6x-5.9x faster** per function and
> **1.6x faster end-to-end** for `parse_request/1`, at the cost of **higher
> transient memory** per call (it allocates intermediate combinator results).
> Behavior is byte-identical: same conformance numbers, 100% parity on the corpus.

---

## 1. Methodology

### Corpus

`bench/corpus.exs` builds inputs from two sources:

1. **Conformance-derived** - every `request.path` query string in
   `spec/conformance/cases/*.yaml` (240 unique query strings), URL-decoded and
   split into the relevant fragments per leaf grammar (filter values, json-path
   columns, order terms, select fields).
2. **Hand-picked edge cases** - json paths (`data->foo->>bar`, `data->>-3`,
   `data->>--34`), quantifiers (`eq(any).{3,4,5}`, `gt(all).{4,3}`), fts language
   (`fts(english).cat`), quoted/balanced-nesting comma splits
   (`{1,"a,b,c",2}`, `deep(a(b(c,d),e),f),g`), related order (`tasks(name).asc`),
   deep json paths, long select lists, dash identifiers (`field-with_sep`),
   malformed inputs.

Per-function input counts (one Benchee invocation processes the whole list):
`parse_json_path` 51, `split_op_value` 121, `valid_identifier?` 10, `embed?` 13,
`aggregate?` 10, `split_alias` 53, `parse_scalar_select` 40, `parse_filter_expr`
13, `parse_order_term` 35; end-to-end `parse_request` 89 query strings.

### Machine / toolchain

| | |
|---|---|
| CPU | Apple M1 Max (10 cores) |
| Memory | 64 GB |
| OS | macOS |
| Elixir | 1.19.5 |
| Erlang/OTP | 28.4 (erts 16.3), JIT enabled |
| Benchee | 1.3 |

### Benchee config

`warmup: 0.5s`, `time: 2s`, `memory_time: 1s`, console formatter. Each scenario
runs the regex reference (`Bench.RegexRef`, a faithful copy of the private
`*_regex` clauses) against the public `Bier.QueryParser.Nimble` twin over the
same input list. The end-to-end scenario flips the real
`:bier, :parser_backend` app env so it exercises the production dispatch in
`Bier.QueryParser.parse_request/1`.

Reproduce:

```sh
MIX_ENV=dev mix run bench/parity.exs        # equivalence proof
MIX_ENV=dev mix run bench/parser_bench.exs   # benchmarks
```

---

## 2. Compatibility result (both backends -> identical conformance numbers)

The backend is selected by `config :bier, :parser_backend, :regex | :nimble`
(default `:regex`); `config/runtime.exs` also honors `BIER_PARSER_BACKEND` so the
suite can be run both ways without editing committed defaults.

| Backend | Command | Result |
|---|---|---|
| `:regex` (default) | `mix test` | **4 doctests, 475 tests, 75 failures (80 excluded)** |
| `:nimble` | `BIER_PARSER_BACKEND=nimble mix test` (x3) | **4 doctests, 475 tests, 75 failures (80 excluded)** |

The `:nimble` run was repeated 3x - deterministic and identical to `:regex`. The
75 pre-existing failures are unrelated to this work (missing DB features:
json-array filter routing, datarep writes, etc.); both backends fail/pass exactly
the same cases.

---

## 3. Parity result (per-function, regex vs nimble)

`bench/parity.exs` asserts identical return values for every corpus input.

| Function | Inputs | Identical |
|---|---:|---|
| `parse_json_path/1` | 51 | 51/51 |
| `split_op_value/1` | 121 | 121/121 |
| `valid_identifier?/1` | 10 | 10/10 |
| `embed?/1` | 13 | 13/13 |
| `aggregate?/1` | 10 | 10/10 |
| `split_alias/1` | 53 | 53/53 |
| `parse_scalar_select/1` | 40 | 40/40 |
| `parse_filter_expr/2` | 13 | 13/13 |
| `parse_order_term/1` | 35 | 35/35 |
| **end-to-end `parse_request/1`** | 89 | **89/89** |

**Total: 346/346 per-function + 89/89 end-to-end inputs identical.**

---

## 4. Benchmark results

`ips` = iterations/sec (higher better); `median` = median run time over the
whole input list (lower better); `mem` = memory per run (lower better);
`speed` = nimble speedup over regex; `memory` = nimble memory relative to regex.

| Function | regex ips | nimble ips | regex median | nimble median | regex mem | nimble mem | **speed** | **memory** |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `parse_json_path/1` | 10.97 K | 61.26 K | 94.67 us | 16.13 us | 50.4 KB | 60.4 KB | **5.59x faster** | 1.20x more |
| `split_op_value/1` | 9.44 K | 42.22 K | 109.9 us | 22.96 us | 56.4 KB | 94.8 KB | **4.47x faster** | 1.68x more |
| `valid_identifier?/1` | 134.7 K | 794.2 K | 6.38 us | 1.21 us | 1.56 KB | 3.73 KB | **5.90x faster** | 2.39x more |
| `embed?/1` | 98.4 K | 218.9 K | 8.63 us | 4.42 us | 1.96 KB | 20.5 KB | **2.23x faster** | 10.5x more |
| `aggregate?/1` | 97.6 K | 153.4 K | 8.83 us | 4.88 us | 3.52 KB | 20.1 KB | **1.57x faster** | 5.72x more |
| `split_alias/1` | 22.5 K | 69.9 K | 36.58 us | 10.83 us | 18.2 KB | 38.5 KB | **3.10x faster** | 2.12x more |
| `parse_scalar_select/1` | 6.35 K | 19.88 K | 157.1 us | 50.79 us | 63.5 KB | 96.7 KB | **3.13x faster** | 1.52x more |
| `parse_filter_expr/2` | 21.2 K | 69.7 K | 41.42 us | 10.92 us | 23.2 KB | 31.8 KB | **3.29x faster** | 1.37x more |
| `parse_order_term/1` | 7.48 K | 17.79 K | 137.0 us | 56.21 us | 58.8 KB | 99.0 KB | **2.38x faster** | 1.68x more |

### End-to-end `parse_request/1`

| | regex | nimble | ratio |
|---|---:|---:|---:|
| ips | 0.75 K | 1.20 K | **1.60x faster** |
| median | 1.31 ms | 0.80 ms | |
| memory | 0.73 MB | 1.04 MB | 1.42x more |

(End-to-end numbers are diluted by the parts that are *not* routed through
nimble - `split_top_commas/1`, the recursive select/logic tree, URL decoding, map
plumbing - which are shared by both backends.)

---

## 5. What was implemented in `nimble_parsec`, and what was not

**Implemented as compiled combinators** (`defparsec`/`defparsecp`,
binary-matching clauses generated at compile time):

- `parse_json_path/1` - `base_col` + repeated `->`/`->>` steps; json-key
  validation (int / `[\w ]+`) done post-parse.
- `split_op_value/1` - `op (mod)? . value`, value captured via `post_traverse`
  (mirrors the regex's `/s` `.*` tail).
- `valid_identifier?/1`, `embed?/1`, `aggregate?/1` - pure grammar predicates.
- `split_alias/1` - greedy `[\w ]*` name + `lookahead_not("::")` boundary.
- `parse_scalar_select/1`, `parse_filter_expr/2`, `parse_order_term/1` - these
  reuse the nimble json-path/identifier parsers and keep the small, non-grammar
  glue (the `::` cast split, the order-modifier table, the error-envelope
  computation) shared with the original.

**Intentionally left on the regex/string path** (and *documented* in the
module), because `nimble_parsec` is the wrong tool there:

- **`split_top_commas/1`** - a character-level, depth-tracking, quote-aware
  *splitter*. It must tolerate arbitrary opaque inner text (`{1,"a,b"}`,
  `deep(a(b,c))`) without parsing it. nimble_parsec is a *parser*; a balanced
  recursive grammar would force parsing the bracket contents and lose the
  tolerant behavior. The existing hand-rolled charlist recursion is already an
  efficient, idiomatic state machine - re-expressing it buys nothing.
- **The recursive grammars** - `parse_select_tree/1`, logic groups `and=(...)`,
  embed sub-selects. These recurse back through `split_top_commas/1` and the leaf
  parsers; routing the *leaves* through nimble already exercises it on the hot
  path. A full `parsec`-recursive select/logic grammar is feasible but would have
  to re-encode the same balanced-split tolerance, with no behavioral gain.
- A handful of **non-grammar string ops** kept shared for byte-identical output:
  the order error-envelope (`order_error/1`), the `::` cast peel, and the
  order-modifier lookup table.

---

## 6. Recommendation

**The `nimble_parsec` leaf grammars are a clear, low-risk win and worth
adopting** - 1.6x-5.9x faster per function and 1.6x faster end-to-end, with
**proven byte-for-byte equivalence** (same conformance numbers, 346/346 + 89/89
parity). The speedup comes from nimble compiling the grammars to direct
binary-matching clauses, replacing PCRE regex compilation/execution and repeated
`String.split`/`Regex.run` passes.

**Caveats and where it loses:**

- **Memory.** Every nimble scenario allocates *more* transient memory (1.2x-10x),
  because combinators build intermediate token lists / tagged keyword results
  that the regex path avoids. `embed?`/`aggregate?` are the worst offenders
  (10x/5.7x) for the *least* speed gain (2.2x/1.6x) - for pure boolean predicates
  the combinator overhead barely pays off. If these turn out hot, a tiny
  hand-written matcher would beat both.
- The end-to-end win (1.6x) is smaller than the per-function wins because the
  shared, un-migrated parts (comma splitting, recursion, URL/map plumbing)
  dominate `parse_request/1`.

**On the stated long-term goal** (a more performant library with **no runtime
`nimble_parsec` dependency**): this exploration shows the grammar *shape* a
hand-written binary-matching parser should target. nimble already lowers to
exactly such clauses, so the realistic path is:

1. Adopt the nimble leaf grammars now (behavior is proven; default stays `:regex`
   until reviewed, flip to `:nimble` when ready).
2. For the eventual zero-dependency goal, **hand-write** the same leaf grammars
   as Elixir binary-pattern functions (`def p(<<"->>", rest::binary>>) ...`) -
   they would match or beat nimble's speed *and* drop the allocations (no
   intermediate token lists), removing both the runtime dep and the memory
   regression. The recursive select/logic tree and `split_top_commas/1` are
   already hand-written and need no change.

A **full** migration of the recursive grammars to nimble is **not** recommended:
it re-encodes balanced-split tolerance the current code already handles cleanly,
for no behavioral or meaningful performance benefit.
