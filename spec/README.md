# Bier conformance spec

This directory is the **behavioral specification** Bier targets: a black-box,
forge-neutral model of how [PostgREST](https://postgrest.org) responds to HTTP
requests, distilled from PostgREST's own public behavior and test suite.

Bier aims to serve a RESTful API generated on-the-fly from PostgreSQL
introspection, "heavily inspired by PostgREST." This `spec/` tree pins down what
that compatibility means, case by case, so it can be checked automatically.

## Pinned version

Everything here targets **PostgREST v16.0** (docs:
[postgrest.org/en/v16](https://postgrest.org/en/v16/)). Every conformance case
carries a `source:` URL pinned to the `v16.0` git tag with a `#L<line>` anchor,
fetchable via `raw.githubusercontent.com`. All **710** cases are pinned to
`v16.0` — verified on disk this pass. Sweeping every PostgREST URL across the 17
area models plus all 710 cases (**727** files, **every one** carrying at least
one citation) with a prefix-aware pattern finds **1846** `raw…/v16.0/` links plus
**71** `github.com/…/blob/v16.0/` links — **1917** citations at a single tag —
and **exactly one** URL at any other tag, described in the next note. When
bumping the target version, re-pin the sources and re-run the review pass.

> **`case.schema.json` does not enforce the pin.** Its `source` pattern is
> `^https://raw\.githubusercontent\.com/PostgREST/postgrest/.+#L[0-9]+$` — the
> `.+` matches *any* tag, so a case pinned to `v14.12` still validates. Only the
> URL sweep above catches stale pins; a green schema run does not. This was
> proved by negative control in an earlier pass and the pattern has not changed
> since.

> **Match the URL prefix, not just the tag.** A naive `grep -v 'postgrest/v16\.0/'`
> reports dozens of false stale hits, because
> `github.com/PostgREST/postgrest/blob/v16.0/…` puts `blob/` between the repo
> and the tag. Sweep with a prefix-aware pattern
> (`postgrest/(raw/|blob/|tree/)?<tag>`) or the count is wrong. Do not anchor on
> `https://` either — several in-scope URLs are written scheme-less.

> **There is now exactly one `v14.12` URL in the audited set, and it is a
> quotation, not a citation.** `spec/rpc.yaml:564` contains
> `https://github.com/PostgREST/postgrest/blob/v14.12/test/spec/fixtures/schema.sql`
> inside an `operator_action` gap entry whose whole purpose is to *report* that
> `conformance/fixtures/rpc.sql#L15` still carries that stale provenance pin, so
> an operator can find and fix it. The machine verification scored **0** stale
> pins because its pattern matches only `raw.githubusercontent.com`; a
> prefix-aware sweep surfaces this one every time. **Do not "fix" the gap entry**
> — fix the fixture comment it is reporting (`COVERAGE.md` → follow-up 24).

> **`v14.12` in prose is not a stale pin.** **115** bare `v14.12` occurrences on
> **113** lines remain across the 17 area model files (`url_grammar.md` 15,
> `pagination.yaml` 14, `errors.yaml` 13, `observability.yaml` 12, `auth.yaml`
> 10, `config.yaml` 9, **`rpc.yaml` 7**, and the rest fewer), plus **26**
> occurrences across **25** case files. These are counted by *occurrence* this
> pass, not by line, which is why some per-file numbers differ from the previous
> revision without the files having changed. Sampling them shows deliberate
> v14.12→v16.0 change notes ("the block is byte-identical to v14.12, only the
> `src/library/` path and line numbers move"). `rpc.yaml` is this pass's mover,
> by four: its re-sync recorded which upstream blocks merely *moved* between the
> pins (`PreferencesSpec.hs` → `Preferences/*Spec.hs`) and which changed.
> (This count deliberately excludes `README.md`, `COVERAGE.md` and
> `conformance/INDEX.md`, which the synthesis phase rewrites; counting files
> against themselves is not a measurement.)
>
> **Five** such notes have been **corrected** rather than carried forward: case
> 1029's claim that the query parser was "byte-identical between the pins";
> case 1016's claim that no v16.0 Feature-spec line existed for the PUT-`limit`
> rule; `pagination.yaml`'s "no pagination behavior changed between the pins",
> narrowed to "no *asserted* behavior changed"; `observability.yaml`'s claim that
> the OPTIONS Server-Timing "subset" was unchanged from v14.12 (the *unchanged*
> half was true, the *subset* half was false at **both** pins, and `lib/` had
> implemented it); and `operators.yaml`'s claim that cases 10200–10219 "closed
> everything in the *existed at both pins, never modeled* bucket" — they had not.
> Treat comparative prose as a claim to re-verify, not as settled fact.
>
> **The rpc pass produced no sixth correction, and that is not the same as
> producing none.** Its audit returned **five** findings of a different species:
> not a false "nothing changed" note, but **no note at all** on five behaviors
> that existed at both pins — including two whole H2 sections of the *Functions
> as RPC* docs page. Read "nothing changed between the pins" as a claim about
> *change*, never as a claim about *coverage*, and read the absence of a note as
> no claim at all.

> **Fixture provenance comments are mostly still on the old pin.** **Seven**
> files under `conformance/fixtures/` carry **44** `v14.12` URLs in `--`
> provenance comments (re-counted on disk this pass, unchanged: `ordering.sql`
> 27, `errors.sql` 5, `auth.sql` 4, `mutations.sql` 3, `config.sql` 2,
> `filters.sql` 2, `rpc.sql` 1). `observability.sql` carried **7** two passes ago
> and now carries **zero**: the observability re-sync re-pinned its whole header
> block to `v16.0` raw URLs, a comment-only change with every anchored line
> number verified unchanged across the pins. It is the only fixture fragment
> re-pinned to v16.0 so far, and whether that becomes the pattern for the other
> seven is an open decision (`COVERAGE.md` → follow-up 14). These files are
> historical provenance and explicitly non-authoritative (the live artifact is
> `conformance/fixtures.sql`), so the re-syncs otherwise leave them alone — but
> do not read "single tag" above as covering `*.sql`. `rpc.sql`'s single stale
> URL is now doubly relevant, because `rpc.yaml` quotes it (see above).

> **v16 source-layout note.** v16 moved the library sources from
> `src/PostgREST/…` to `src/library/PostgREST/…` (a new `src/executable/` tree
> holds the CLI). Source anchors into implementation files therefore carry the
> `src/library/` prefix; the old `src/PostgREST/` anchors are stale *paths*, not
> merely stale line numbers.

## What's here

```
spec/
├── README.md                  # this file
├── COVERAGE.md                # docs-page -> covering case ids; gaps + verification
├── case.schema.json           # JSON Schema for a single conformance case
├── <area>.yaml | url_grammar.md   # 17 per-area behavior models (the "why")
└── conformance/
    ├── INDEX.md               # area <-> id band <-> fixture cross-reference
    ├── cases/NNNN_<slug>.yaml # 710 conformance cases (the "what", machine-checkable)
    ├── fixtures.sql           # the authoritative merged DDL+seed set
    ├── fixtures_local.sql     # human-owned harness supplement
    └── fixtures/              # per-area fragments + write-channel deltas (see its README)
```

There are two layers:

1. **Area behavior models** — one file per feature area
   (`url_grammar.md` plus 16 `.yaml` files: `operators`, `select`, `filters`,
   `ordering`, `pagination`, `representations`, `mutations`, `rpc`, `auth`,
   `errors`, `headers`, `content_negotiation`, `openapi`, `config`,
   `observability`, `domain_representations`). These describe the grammar,
   defaults, and rules of an area in prose/structured form, each claim citing a
   PostgREST source line. They are the human-readable rationale. All 17 declare
   the v16.0 pin, but the key spelling is not uniform on disk: 10 use
   `version: v16.0`, 5 use `version: PostgREST v16.0` (`errors`, `filters`,
   `observability`, `operators`, `ordering`), `pagination.yaml` uses
   `postgrest_version: v16.0`, and `url_grammar.md` states it in prose
   ("Version pinned: **PostgREST v16.0**"). Do not grep for a single spelling.

   > **Counted on disk this pass: neither the presence nor the length of a gap
   > list means what it looks like.** **Four** of the 17 models carry no `gaps:`
   > key anywhere: `errors.yaml` (which records coverage under `coverage:`, its
   > open items inline, and a `harness_gate:` key naming the Bier-side wiring
   > three of its cases need) and `content_negotiation.yaml`, `operators.yaml`
   > and `representations.yaml`, which record **no gap list at all, under any
   > key**. `url_grammar.md` uses a `## Gaps` markdown section rather than a YAML
   > key. The remaining **twelve** `.yaml` models carry between **5** and **16**
   > entries:
   > `config.yaml` and `observability.yaml` **16** each, `auth.yaml` **15**,
   > `filters.yaml` **14**, `pagination.yaml` / `select.yaml` **11** each,
   > `headers.yaml` / `rpc.yaml` **7** each, `mutations.yaml` / `openapi.yaml` /
   > `ordering.yaml` **6** each, `domain_representations.yaml` **5**. Read the
   > model; do not assume the shape.
   >
   > **A long list is not coverage, and `rpc.yaml` is the proof.** Its seven
   > entries are unusually rigorous — two argue at length against *approximating*
   > a behavior rather than omitting it — and its audit still returned **five**
   > findings, none of which any entry anticipated. Length measures how carefully
   > an author declined the gaps they *saw*.
   >
   > **Silence is likewise ambiguous.** `operators.yaml` was audited and came
   > back ✅ *pass* with **0 citation defects** while still carrying no gap list
   > under any key, so silence is no longer uniformly "un-audited absence" — for
   > `operators` it is audited absence, and its open items live only in
   > `COVERAGE.md`. The other two silent models, `content_negotiation.yaml` and
   > `representations.yaml`, remain among the **five** areas with no recorded
   > v16.0 adversarial verdict, so their silence is still indistinguishable from
   > never having been examined (see *Review status*).

2. **Conformance cases** — 710 YAML files under `conformance/cases/`. Each is one
   concrete scenario: a request and the exact response (status, headers, body)
   PostgREST produces. These are the machine-checkable contract.

## Anatomy of a conformance case

Each case validates against [`case.schema.json`](case.schema.json):

```yaml
id: 1200                       # globally-unique; each area owns an id band
feature: ordering/direction/asc  # slash-delimited <area>/<sub-feature>/...
request:
  method: GET                  # HTTP shape: method + path
  path: /items?id=lte.2&order=id.asc
  headers: { Accept: application/json }
schema: ordering               # fixture-set LABEL (see "Fixtures" below)
preconditions: []              # optional SQL, declarative only — see the note
config: {}                     # optional PostgREST config the case requires
expect:
  status: 200
  headers:
    Content-Range: "0-1/*"
  body_exact: [ ... ]          # body_exact | body_jsonpath | body_contains | body_raw | body_json
notes: "..."                   # rationale, references the upstream it-block
source: https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/...#L<n>
```

The schema's `required` list is six keys — `id`, `feature`, `request`, `schema`,
`expect`, `source` — but in practice `notes` is universal too: all seven are
present on all **710** cases, verified mechanically this pass by intersecting key
sets rather than by trusting the schema. The complete key vocabulary on disk is
exactly those seven plus `preconditions` and `config`; nothing else appears.
`preconditions` is present on **709** (case **1330** omits it);
`config` is present on **116** (four of those — 1705, 1719, 1727, 1743 — are the
empty `config: {}`). **The config count has not moved for two passes**: none of
the operators re-sync's 37 new cases and none of the rpc re-sync's 3 declares a
`config:` block, because neither area is config-gated — a useful contrast with
`select`, whose aggregate cases all need `db-aggregates-enabled`.

Two request shapes are supported:

- **HTTP** (the common case, **672** cases): `request.method` + `request.path`,
  with optional `request.headers` / `request.body` / `request.body_raw` /
  `request.body_json`. The **auth** area may add `request.jwt` to have the runner
  mint and send a signed token (32 cases do; case 11809 instead spells out a
  literal `Authorization` header, because it needs a token signed with a secret
  the harness does not know).
- **CLI** (config startup behavior, 38 cases — all of them in `config`,
  ids **1705–1741 plus 1744**; the band is *not* contiguous, because 1742/1743
  are HTTP CORS cases sitting inside it): `request.kind: cli` with
  `request.flag: "--dump-config"`, asserting on `expect.exit_code`,
  `expect.dump_contains`, `expect.dump_reparse_stable`, and
  `expect.stderr_contains`.

Response assertions include `status`/`status_text`/`exit_code`, exact or pattern
header matches (`headers`, `headers_match`, `headers_present`, `headers_absent`,
`headers_absent_in_value`, `headers_no_blank`), and body assertions
(`body_exact`, `body_jsonpath`, `body_contains`, `body_raw`, `body_json`). See
the schema for the authoritative field list and descriptions.

> **`preconditions:` are declarative documentation only.** The frozen harness
> parses the field but never executes it; nothing in a case may depend on a
> precondition having run. `spec/pagination.yaml` records the sharpest instance:
> cases 1272/1274/1275 carry `preconditions: ["ANALYZE …"]` for planner-estimate
> expectations and pass only because `mix bier.fixtures.load` happens to run a
> database-wide `ANALYZE`.

> **One request shape is entirely untested: a `HEAD` that errors.** Thirteen
> cases use `HEAD` (1020, 1272, 1274, 1275, 1277, 1284, 1425, 1681, 1756, 1760,
> 1761, 1762, 1771) and **every one expects a 2xx** — re-derived mechanically at
> the 710-case state. The last three re-syncs added 42 cases between them without
> adding a single erroring HEAD, so the blind spot's denominator keeps growing.
> `COVERAGE.md` → *Known gaps → errors* costs the fix at one case.

## Fixtures

The conformance database is built by `mix bier.fixtures.load` from
`conformance/fixtures.sql` (the authoritative artifact) plus the human-owned
`conformance/fixtures_local.sql`, followed by area-schema mirroring. A case's
`schema:` field is a **fixture-set label, not a filename**: the harness sends
any label other than `null`/`public`/`test` as an `Accept-Profile: <label>`
request header, so the label must name a schema the conformance server exposes
*or* resolve through one of the server's aliases/profile lists (`unicode` →
`تست`) *or* through the implementation-side allowlist (`multi` and `headers`;
see below). The harness sets the header with `Map.put_new`, so a case that spells
out its own `Accept-Profile` wins over the label.

> **Counted on disk this pass, unchanged.** **Fifteen** cases spell out a
> profile header of their own: **1009–1014, 1017, 1018, 1023, 1024** (ten of the
> fourteen `multi` cases) and **1558, 1559, 1560, 1574, 1583** (five `headers`
> cases). But only an explicit **`Accept-Profile`** suppresses the injection —
> `Content-Profile` does not — so of the fifteen, **twelve** actually suppress it
> and **three** (1011, 1012, 1559) do not. The consequence is that **six** `multi`
> cases receive `Accept-Profile: multi`: **1005–1008** (which set no profile
> header at all) and **1011**/**1012** (which set only `Content-Profile`).
>
> **And `multi` is not resolved by the harness at all.** It is neither a schema
> in `bier_test` nor a `db_schema_aliases` key; it resolves only because
> *implementation* code carries a hard-coded allowlist of conformance labels
> (`@profile_aliases ~w(headers multi)`,
> `lib/bier/plugs/action_controller.ex:479`) — re-verified on disk this pass.
> Three of the six (**1005**, **1008**, **1011**) expect a 2xx and therefore
> depend on that allowlist. See `COVERAGE.md` → *Open verification findings*.
> Note the machine check does **not** flag them, because its label-resolution
> step maps `multi` to the `v1`/`v2` pair itself; that is a property of the
> checking script, not a fix to the tree.

The fixture set also carries one **renamed** relation worth knowing about, because
four cases now point at a path upstream does not use: upstream's `menagerie` is
the pagination fixture's single-column *empty* table, but `openapi.sql`
contributes a 7-column type-mapping table of the same name. The consolidated
fixture keeps openapi's as `test.menagerie` and renames the empty one to
`test.menagerie_empty`; the pagination re-sync retargeted cases **1258, 1264,
1266 and 1268** onto `/menagerie_empty`, since emptiness is the whole point of
those four assertions.

Ownership rules for everything under `conformance/fixtures/` — who may write
which file, and why `<area>.delta.sql` is the only write channel — are in
[`conformance/fixtures/README.md`](conformance/fixtures/README.md). There are
**17** per-area fragments and **7** `*.delta.sql` write channels; all seven are
**comment-only**, re-verified mechanically this pass (stripping comment and blank
lines leaves zero lines in every one). Each holds a single
`-- Folded into ../fixtures.sql on <date> (…); empty until the next delta.`
provenance line and no DDL, i.e. empty as a write channel. Four carry the
2026-08-08 date (`content_negotiation`, `headers`, `ordering`, `rpc`); three
carry 2026-08-09 (`url_grammar`, `errors`, `operators`).

> **The rpc re-sync added no channel and no object, and that was the right
> call.** `fixtures.sql` does not appear in `git status`; `rpc.delta.sql` is
> unchanged. All three new cases run against routines the consolidated fixture
> already had (`rpc.ret_void`, `rpc.variadic_param`) or, for case 1443, against
> the deliberate *absence* of `test.sayhell` beside the present `test.sayhello`.
> Its audit's three fixture-blocked findings were left **open and recorded**
> rather than half-closed with substitutes — and their blocker is
> **ownership**, not absence: the routines belong in the human-owned
> `fixtures/rpc.sql`, which no workflow agent may edit, so a spec pass can only
> reach schema `test` through `rpc.delta.sql`. Decide that once
> (`COVERAGE.md` → follow-up 22) before authoring any of them.

> **The operators re-sync is the only one so far to add fixture objects through
> a delta.** `operators.delta.sql` records the fold of
> `test.items_with_different_col_types` (one column per base type, with
> upstream's single `int_data = 1` seed row), `test.tsearch_to_tsvector` (the
> same five documents as the pre-existing and **distinct** `test.tsearch`, but
> stored unconverted as text/jsonb/domain so the automatic `to_tsvector()`
> coercion is what does the work), the two domains `test.tsvector_not_null` and
> `test.tsvector_not_empty` (the second defined over the first, which is what
> makes a *recursive* tsvector domain distinguishable from a plain one), and the
> computed field `test.text_search_vector(test.tsearch_to_tsvector)`. Nothing was
> renamed — no folded name collided — and no `GRANT` was needed, because the
> loader mirrors `test` relations into the area schemas as views.

> **One existing fragment *was* edited (once, by an earlier re-sync), and the
> exception is narrow enough to state precisely.** The observability re-sync
> modified `conformance/fixtures/observability.sql` — **comment-only**: it
> re-pinned the header's provenance URLs from `blob/v14.12` to `raw/v16.0` (all
> seven anchored line numbers verified unchanged) and added two missing
> provenance lines for objects the file already created. No DDL, no seed row, no
> object added, removed or altered. That is the only kind of edit to an existing
> fragment a re-sync has made; anything touching *objects* still goes through a
> `<area>.delta.sql`.

See [`conformance/INDEX.md`](conformance/INDEX.md) for the full
area ↔ id-band ↔ fixture ↔ label map.

## How this drives the Tester

This `spec/` tree is the output of the spec-research phase. The **Tester**
consumes it: `test/conformance/conformance_test.exs` generates one ExUnit test
per case, `test/support/conformance_server.ex` boots the shared instances (plus
per-case config variants), and `Bier.HttpCase`/`Bier.CliCase` replay the request
and assert the response matches `expect`. The Tester owns `case.schema.json` and
the CI lint gate. The area models guide implementation; the cases are the
pass/fail contract.

> `CLAUDE.md` still says "532 cases". That is stale relative to this tree, which
> holds **710**.

Everything under `spec/` and `test/` is **frozen ground truth** for
implementation work: fix `lib/` to match the cases, never edit the cases to
match `lib/`. The two scoped exceptions (re-syncing to a new PostgREST pin via
the `bier-spec` / `bier-spec-audit` workflows, and human-reviewed edits to
`fixtures_local.sql`) are described in `CLAUDE.md`.

## Validating cases locally

```sh
pip install pyyaml jsonschema
python3 - <<'PY'
import glob, yaml, json, jsonschema
schema = json.load(open("spec/case.schema.json"))
v = jsonschema.Draft202012Validator(schema)
bad = 0
for f in glob.glob("spec/conformance/cases/*.yaml"):
    for e in v.iter_errors(yaml.safe_load(open(f))):
        bad += 1; print(f, e.message)
print("OK" if not bad else f"{bad} errors")
PY
```

All **710** cases currently parse and validate, with **no duplicate ids** (710
files, 710 distinct ids, and every `NNNN_` filename prefix equals the in-file
`id:` — re-derived across both 5-digit bands). Toolchain: PyYAML **6.0.3**,
jsonschema **4.26.0**, `Draft202012Validator`. Remember the caveat above: a clean
run proves shape, not pin — the `source` pattern accepts any tag. The validator
was proved live, not vacuous, by negative controls on a mutated copy of a
pristine case (unknown key, dropped required key, wrong `id` type, and a
malformed `source` were all caught); the one control it **fails** is the
stale-pin rewrite, which is why the URL sweep above exists. Those controls were
run in an earlier pass and are not repeated every time — the failure they record
is a property of the schema's `source` pattern, which has not changed.

## Review status

Citations are **self-reported**: every case carries a pinned `source:` URL with
a line anchor. The v16.0 re-sync's adversarial review — re-fetching the cited
line and confirming it still asserts what the case claims — is summarized
per area in [`COVERAGE.md`](COVERAGE.md), together with the open gaps and the
machine-verification results for this pass.

**Twelve** areas carry a recorded v16.0 adversarial verdict so far, and **every
one of the twelve reports 0 citation defects** — no verdict has ever turned on a
mis-cited line. Ten are ⚠️ *revise*: **auth**, **headers**, **config**,
**select**, **filters**, **ordering**, **url_grammar**, **pagination**,
**observability** and now **rpc**, every finding a missing-coverage or
mis-modelled-rule gap itemized in `COVERAGE.md` → *Known gaps*. **Two** are
✅ *pass*: **errors** and **operators**, whose findings are all explicitly MINOR /
non-blocking. The other **5** areas — `representations`, `mutations`,
`content_negotiation`, `openapi`, `domain_representations` — have not been
re-audited at this pin; run `bier-spec-audit` over them before treating their
citations as verified.

> **The rpc verdict is the strongest argument yet for finishing the remaining
> five, because it is the first audit to hit an area this same workflow had just
> re-synced.** It returned **five** findings — the most any single area audit has
> produced — including **two whole H2 sections of the *Functions as RPC* docs
> page** with no case, no model entry and no gap note: *Untyped functions*
> (routines returning `record` / `SETOF record`) and *Functions with array
> parameters* (a **non**-variadic array-typed parameter). Also missing: the
> `text/plain` and `text/xml` flavors of the single unnamed parameter (only the
> bytea flavor is covered, and from the *content_negotiation* area), resource
> embedding through a table-valued function (exercised only incidentally, by a
> `url_grammar` case), and `?columns=` on an RPC POST. **A completed re-sync is
> not evidence of coverage; only an audit is.**

> **The operators pass is the only one to close another area's gap, and that is a
> structural note, not a scoreboard entry.** The `IN`/`NOT IN` empty-set behavior
> was raised as a **filters** gap ("no case in the whole tree issues an `in.()`
> request"). It is now covered by operators cases **10200–10205** against a folded
> `test.items_with_different_col_types`, because the *SQL rendering* of `in` —
> the `[""] -> "= ANY('{}')"` branch — was already modelled in `operators.yaml`.
> When a gap's docs page and its source-level rule live in different areas, the
> gap will be recorded by one and closed by the other; check `COVERAGE.md`'s gap
> sections against disk before assuming a listed gap is still open.

> **Two verdicts should be read as warnings about the remaining five, and the
> second is the sharper one.**
>
> The **pagination** findings were not merely "a case is missing": one modelled
> *rule* was **wrong** — the Range header was documented as *overriding*
> limit/offset, when `getRanges` **intersects** them — and the single upstream
> it-block on the subject (`RangeSpec.hs#L194`, case 1261) is the one shape where
> the two rules coincide, so no existing case could have caught it.
>
> The **observability** findings went one step further: the modelled rule that
> `OPTIONS` responses omit the `plan` and `transaction` Server-Timing metrics was
> false at **both** pins, three cases asserted it, **and `lib/` implemented it**
> (`lib/bier/plugs/observability.ex:159`). Spec and implementation agreed with
> each other and with nothing upstream, so the suite was green on an invented
> behavior. A green suite is not evidence that a model is right; it is not even
> evidence that the behavior exists.

Note what "zero citation defects" does *not* mean: **46** cases anchor their
`source:` at implementation code under `src/library/PostgREST/…` rather than at
an upstream `it`-block, so their expected bodies are derived rather than
transcribed. **The count has now been flat for two consecutive passes** (its
history is 36 → 42 → **46 → 46 → 46**): all 37 operator cases and all three rpc
cases anchor at real `it`-blocks, so the implementation-anchored *share* fell to
**6.5 %** (46/710) without a single re-anchoring in either direction. The rpc
pass is the more interesting of the two, because it **rewrote six cases and moved
zero anchors** — rewriting is historically where anchors move, so the six were
already right. Earlier passes did move anchors in both directions — **1189**
(filters), **1016** (url_grammar) and **1767** (observability) moved *off*
implementation code; 1757/1768/1769 moved *onto* it when a retracted claim could
only be refuted at the control flow — and each direction is a finding worth
reading. Separately, case **1279** is the tree's **first and only case anchored
at the documentation** rather than at either the test suite or the source
(`docs/references/api/pagination_count.rst#L52`, the open-ended `Range: 10-`
paragraph). The rest are behaviors upstream never asserts black-box, and each
says so in its `notes:`.
