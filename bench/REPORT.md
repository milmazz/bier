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

---

## 7. Combinator reuse (compile-time)

NimbleParsec's docs (`parsec/2`, "the only situation where you should use
`parsec/2` for composition is when a large parser is used over and over again in
a way compilation times are high … you can use `parsec/2` to improve compilation
time at the cost of runtime performance") motivated a pass to replace
*inlined-twice* combinators in the templates with a single `defcombinatorp` +
`parsec(:p_<name>)` reference, to shrink the generated code and the compiler's
compile-time AST.

### 7.1 What was cleanly hoistable vs blocked

The templates (`lib/bier/query_parser/nimble.ex.exs`,
`lib/bier/query_parser.ex.exs`) define grammar fragments as plain combinator
*variables* and inline them into each `defparsecp`. Candidates were any fragment
inlined 2+ times.

**Cleanly hoistable — no `--warnings-as-errors` conflict (explored, then
reverted; see §7.4 — all in `nimble.ex.exs`):**

| Combinator | Grammar | Use sites | Position |
|---|---|---|---|
| `:p_fun_token` (`[a-z_]+` → string) | `p_agg_call`, `p_aggregate` | 2 | mandatory `concat` |
| `:p_ctl_ws_run` (`repeat([\s\t\n\r\f\v])`) | `p_agg_call`, `p_logic_prefix` | 2 | mandatory `ignore(parsec(…))` |
| `:p_name_run` (`[A-Za-z_][\w ]*` char run, no `reduce`) | `p_embed_parts`, `p_related_order` | 2 | mandatory leading element |

Net: **4 inlined copies → 2 shared combinators** across three grammar pairs.

**Blocked by `--warnings-as-errors` (kept inlined):**

| Candidate | Where | Why blocked |
|---|---|---|
| `name_token` (`[A-Za-z_][\w ]*` → string) | 7 sites in `p_embed`/`p_aggregate`/`p_agg_call`/`p_alias` | 5 of 7 sites are inside `optional(…)`/`repeat(…)` |
| `identifier` | 3 sites in `select` (`query_parser.ex.exs`) | whole `select` is `choice([default, detailed])` |
| `cast_separator`, `filter_separator` | `select` / `horizontal_filter` | sit under `select`'s top-level `choice` and `horizontal_filter`'s `optional |> choice` |

**Root cause of the block (the Phase-2 finding, now pinpointed).** When
`parsec(:name)` is expanded inside a *backtracking* context (`optional`,
`repeat`, `choice`), NimbleParsec's compiler emits a dispatch clause of the form

```elixir
case p_name__0(rest, acc, [], context, line, offset) do
  {:ok, acc, rest, context, line, offset} -> next(...)
  {:error, _, _, _, _, _} = error -> backtrack(...)   # `error` bound, never used
end
```

The backtracking branch discards `error` (it pops the stack instead), so the
generated file has an `unused variable "error"` warning → fails under
`--warnings-as-errors`. In a *mandatory* position the same expansion is
`{:error, …} = error -> error` (the value is returned, so it IS used) and the
file stays clean. This is a property of NimbleParsec's generator, not something
the template can restructure away without changing grammar semantics — so every
reuse where the call site is under `optional`/`repeat`/`choice` is genuinely
blocked.

Three structural tricks were used to *keep* a reuse on the clean side of that
line: (a) `:p_ctl_ws_run` captures the backtracking `repeat/1` *inside* the
combinator, so the call site is the mandatory `ignore(parsec(:p_ctl_ws_run))`;
(b) `:p_name_run` is referenced only as the mandatory *leading* element of two
`defparsecp` entry points (never wrapped); (c) `:p_fun_token` carries no tag, so
the `unwrap_and_tag(:fun)` stays at the (mandatory) use site. `name_token` itself
is deliberately **not** redefined as `parsec(:p_name_run) |> reduce(...)`,
because that would re-introduce the inner `parsec` into all of `name_token`'s
`optional(...)` call sites and re-trip the warning.

`query_parser.ex.exs` (the legacy `select`/`horizontal_filter` grammars) yielded
**zero** clean candidates: every repeated fragment there lives under the
top-level `choice`/`optional`, so its template is unchanged by this pass.

### 7.2 Before/after measurements

**Generated code size** (`wc -l -c`):

| File | LOC before | LOC after | bytes before | bytes after |
|---|---:|---:|---:|---:|
| `lib/bier/query_parser/nimble.ex` | 2812 | 2777 | 91 126 | 90 020 |
| `lib/bier/query_parser.ex` | 2139 | 2139 | 77 228 | 77 228 |
| **total** | **4951** | **4916** | **168 354** | **167 248** |

Net **−35 LOC / −1106 bytes** (−1.2% of `nimble.ex`; the `query_parser.ex`
parser is untouched because no candidate was clean).

**Compile wall-time + peak RSS.** Apple M1 Max, Elixir 1.19.5 / OTP 28.
`rm -rf _build/dev/lib/bier && /usr/bin/time -l mix compile --warnings-as-errors`
(deps pre-compiled, so only the `bier` app — dominated by the two generated
parsers — recompiles). 3 iterations each, same session, median reported:

| | clean rebuild wall (median) | clean rebuild peak RSS (median) | touch+recompile wall (median) |
|---|---:|---:|---:|
| **before** (inlined) | 0.97 s | 268 MB | 0.42 s |
| **after** (parsec reuse) | 0.97 s | 276 MB | 0.43 s |

The differences are **inside the run-to-run noise** (RSS varied 264–283 MB
between iterations of a *single* configuration). At these parser sizes the four
deduplicated fragments are far too small to move compile time or peak RSS.

### 7.3 Runtime trade-off

Each `parsec/1` adds a stacktrace entry at parse time (NimbleParsec docs:
"runtime performance is degraded as `parsec` introduces a stacktrace entry"). A
focused micro-bench (warmup 0.5 s, time 2 s) of the four affected functions,
inlined vs reused:

| Function (reuse) | before ips | after ips | Δ |
|---|---:|---:|---:|
| `logic_prefix` (`:p_ctl_ws_run`) | 1195 K | 1148 K | ~−4% (±950% dev — noise) |
| `aggregate?` (`:p_fun_token`) | 208 K | 207 K | ~0% |
| `parse_embed_parts` (`:p_name_run`) | 211–218 K | 206 K | ~−3% |
| `parse_order_term` (`:p_name_run`) | 26.3 K | 26.2 K | ~0% |

The stacktrace-frame cost is real in principle but **below the measurement
floor** here (deviations dwarf the deltas); parity stays 346/346 + 89/89.

### 7.4 Verdict

**Combinator reuse is not worth much for this codebase.** The two parsers are
small (~90 KB / ~2800 LOC generated), so the `defcombinatorp`/`parsec` pass that
NimbleParsec recommends *only for large, compile-time-expensive parsers* buys a
−1.2% generated-size reduction and **no measurable compile-time or RSS
improvement**, while adding (immeasurably small) runtime stacktrace overhead and
template complexity. The dominant reuse target — the `name_token`/`identifier`
name grammar — is **structurally blocked**: its call sites are overwhelmingly
inside `optional`/`repeat`/`choice`, where `parsec` reuse trips
`--warnings-as-errors`, so the highest-value dedup is exactly the one we cannot
take cleanly.

The three reuses that are *cleanly applicable* (`:p_fun_token`, `:p_ctl_ws_run`,
`:p_name_run`) are a wash on every measured axis, so they were **reverted** — the
committed parsers stay fully inlined, which is the fastest at runtime and matches
the performance goal. This section is the record of that exploration. The honest
conclusion matches the doc's own guidance: reach for `parsec/1` composition only
when a *large* parser's compile time actually hurts — which is not the case here.

> Reproduce: regen + size diff with `mix gen.parsers && wc -l -c
> lib/bier/query_parser.ex lib/bier/query_parser/nimble.ex`; compile RSS with
> `rm -rf _build/dev/lib/bier && /usr/bin/time -l mix compile
> --warnings-as-errors` (×3, deps pre-warmed).
