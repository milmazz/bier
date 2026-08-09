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
fetchable via `raw.githubusercontent.com`. All **657** cases are pinned to
`v16.0` — verified on disk this pass (a sweep of every PostgREST URL across
`spec/*.yaml`, `spec/*.md` and the case files found **exactly one tag**). When
bumping the target version, re-pin the sources and re-run the review pass.

> **`case.schema.json` does not enforce the pin.** Its `source` pattern is
> `^https://raw\.githubusercontent\.com/PostgREST/postgrest/.+#L[0-9]+$` — the
> `.+` matches *any* tag, so a case pinned to `v14.12` still validates. Only the
> URL sweep above catches stale pins; a green schema run does not.

> **Match the URL prefix, not just the tag.** A naive `grep -v 'postgrest/v16\.0/'`
> reports dozens of false stale hits, because
> `github.com/PostgREST/postgrest/blob/v16.0/…` puts `blob/` between the repo
> and the tag. Sweep with a prefix-aware pattern
> (`postgrest/(raw/|blob/|tree/)?<tag>`) or the count is wrong.

> **`v14.12` in prose is not a stale pin.** **96** bare `v14.12` occurrences
> remain across the 17 area model files (`url_grammar.md` 15, `errors.yaml` 13,
> `auth.yaml` 10, `config.yaml` 9, and the rest fewer), plus **25** across 24
> case files. Sampling them shows deliberate v14.12→v16.0 change notes ("the
> block is byte-identical to v14.12, only the `src/library/` path and line
> numbers move"). Verified this pass: **zero** of them carries a `v14.12` *URL*
> — they are comparative prose, not citations. (This count deliberately excludes
> `README.md`, `COVERAGE.md` and `conformance/INDEX.md`, which the synthesis
> phase rewrites; counting files against themselves is not a measurement.)
>
> Two such notes have been **corrected** rather than carried forward, one per
> re-sync: case 1029's claim that the query parser was "byte-identical between
> the pins" (false at the module level — the body is unchanged with an +8 line
> offset, but the header is not) and case 1016's claim that no v16.0 Feature-spec
> line existed for the PUT-`limit` rule (`UpsertSpec.hs#L295` asserts it in both
> pins). Treat comparative prose as a claim to re-verify, not as settled fact.

> **Fixture provenance comments are still on the old pin.** Eight files under
> `conformance/fixtures/` carry **51** `v14.12` URLs in `--` provenance comments
> (re-counted on disk this pass: `ordering.sql` 27, `observability.sql` 7,
> `errors.sql` 5, `auth.sql` 4, `mutations.sql` 3, `config.sql` 2, `filters.sql`
> 2, `rpc.sql` 1). Those files are historical provenance and explicitly
> non-authoritative (the live artifact is `conformance/fixtures.sql`), so the
> re-sync left them alone — but do not read "single tag" above as covering
> `*.sql`. See `COVERAGE.md` → *Validation status*.

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
    ├── cases/NNNN_<slug>.yaml # 657 conformance cases (the "what", machine-checkable)
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
   PostgREST source line, and each closing with an explicit gap list of
   behaviors that were *not* modeled and why. They are the human-readable
   rationale. All 17 declare the v16.0 pin, but the key spelling is not uniform
   on disk: 10 use `version: v16.0`, 5 use `version: PostgREST v16.0`
   (`errors`, `filters`, `observability`, `operators`, `ordering`),
   `pagination.yaml` uses `postgrest_version: v16.0`, and `url_grammar.md`
   states it in prose ("Version pinned: **PostgREST v16.0**"). Do not grep for
   a single spelling.

   > The gap list is not uniform either. Most models close with a top-level
   > `gaps:` key; **`errors.yaml` does not** — it records coverage under
   > `coverage:` (grouped by rule, with `case_ids`) and its open items inline in
   > the relevant section, plus a `harness_gate:` key naming the Bier-side
   > wiring three of its cases need. Read the model, do not assume the schema.

2. **Conformance cases** — 657 YAML files under `conformance/cases/`. Each is one
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

`id`, `feature`, `request`, `schema`, `expect`, `notes` and `source` are present
on all 657 cases — verified mechanically this pass, not assumed.
`preconditions` is present on 656 (case **1330** omits it);
`config` is present on **115** (four of those — 1705, 1719, 1727, 1743 — are the
empty `config: {}`). The count moved 114 → 115 this pass, entirely from the
errors area's new case 1522.

Two request shapes are supported:

- **HTTP** (the common case, 619 cases): `request.method` + `request.path`, with
  optional `request.headers` / `request.body` / `request.body_raw` /
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
> precondition having run.

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

> **Correction, counted on disk this pass.** **Fifteen** cases spell out a
> profile header of their own: ten of the fourteen `multi` cases (**1009–1014,
> 1017, 1018, 1023, 1024**) and five `headers` cases (**1558–1560, 1574, 1583**).
> But only an explicit **`Accept-Profile`** suppresses the injection —
> `Content-Profile` does not — so **six** `multi` cases actually receive
> `Accept-Profile: multi`: **1005–1008** (which set no profile header at all) and
> **1011**/**1012** (which set only `Content-Profile`). Earlier revisions of this
> file said four; the two extra were missed by crediting `Content-Profile` with
> a suppression it does not perform.
>
> **And `multi` is not resolved by the harness at all.** It is neither a schema
> in `bier_test` nor a `db_schema_aliases` key; it resolves only because
> *implementation* code carries a hard-coded allowlist of conformance labels
> (`@profile_aliases ~w(headers multi)`,
> `lib/bier/plugs/action_controller.ex:479`). Machine verification flagged
> **1005, 1008 and 1011** — the three of the six whose expected status is 2xx —
> as targeting unresolvable relations for exactly this reason. See
> `COVERAGE.md` → *Open verification findings*.

Ownership rules for everything under `conformance/fixtures/` — who may write
which file, and why `<area>.delta.sql` is the only write channel — are in
[`conformance/fixtures/README.md`](conformance/fixtures/README.md). There are
**17** per-area fragments and **6** `*.delta.sql` write channels; all six deltas
are currently **comment-only** — each holds a single
`-- Folded into ../fixtures.sql on <date> (…); empty until the next delta.`
provenance line and no DDL, i.e. empty as a write channel. Four carry the
2026-08-08 date; two carry **2026-08-09**: `url_grammar.delta.sql` (case 1035's
`test."Server Today"` + its five upstream seed rows) and the new
`errors.delta.sql` (cases 1523/1524's `test.infinite_inserts` — table, same-named
trigger function and `do_infinite_inserts` trigger — plus the self-referential
`test.infinite_recursion` view). Those are the only fixture objects added by the
last four area re-syncs: filters, ordering, url_grammar and errors together
produced 29 cases and three new relations.

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

All **657** cases currently parse and validate, with **no duplicate ids** (and
every `NNNN_` filename prefix equals the in-file `id:`). Remember the caveat
above: a clean run proves shape, not pin — the `source` pattern accepts any tag.
The validator was proved live, not vacuous, by negative controls on a mutated
copy of a pristine case (dropped `id`, `status: 99`, unknown key, missing `#L`
anchor all caught); the one control it **failed** is the stale-pin rewrite, which
is why the URL sweep above exists.

## Review status

Citations are **self-reported**: every case carries a pinned `source:` URL with
a line anchor. The v16.0 re-sync's adversarial review — re-fetching the cited
line and confirming it still asserts what the case claims — is summarized
per area in [`COVERAGE.md`](COVERAGE.md), together with the open gaps and the
machine-verification results for this pass.

**Eight** areas carry a recorded v16.0 adversarial verdict so far. Seven —
**auth**, **headers**, **config**, **select**, **filters**, **ordering** and
**url_grammar** — are ⚠️ *revise* with **zero citation defects** (every finding
is a missing-coverage gap, itemized in `COVERAGE.md` → *Known gaps*). The eighth,
**errors**, is the tree's first ✅ *pass*: three findings, all explicitly marked
MINOR / non-blocking, and again zero citation defects. The other **9** areas have
not been re-audited at this pin; run `bier-spec-audit` over them before treating
their citations as verified.

Note what "zero citation defects" does *not* mean: **36** cases anchor their
`source:` at implementation code under `src/library/PostgREST/…` rather than at
an upstream `it`-block, so their expected bodies are derived rather than
transcribed (re-counted at the 657-case state). The count moved 34 → 36 because
the errors re-sync added two such cases — **1522** and **1526**, both anchored at
`Response.hs`, both pinning properties of the **inline** 416 body that
`errorResponseFor` never sees and that upstream therefore never asserts
black-box. Two cases have been moved *off* implementation code so far —
**1189** during the filters re-sync and **1016** during the url_grammar re-sync,
the latter also retiring a false "no Feature spec line exists" claim in its
`notes:`. The rest are behaviors upstream never asserts black-box, and each says
so in its `notes:`. That two of the last four re-syncs each found one such case
worth moving suggests the remaining 36 are worth re-reading rather than
accepting.
