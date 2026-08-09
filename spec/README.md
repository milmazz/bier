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
fetchable via `raw.githubusercontent.com`. All **620** cases are pinned to
`v16.0` — verified on disk this pass (a sweep of every PostgREST URL across
`spec/*.yaml`, `spec/*.md` and the case files found **1664** references and
exactly one tag). When bumping the target version, re-pin the sources and re-run
the review pass.

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
    ├── cases/NNNN_<slug>.yaml # 620 conformance cases (the "what", machine-checkable)
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
   PostgREST source line, and each closing with an explicit `gaps:` list of
   behaviors that were *not* modeled and why. They are the human-readable
   rationale. All 17 declare the v16.0 pin, but the key spelling is not uniform
   on disk: 10 use `version: v16.0`, 5 use `version: PostgREST v16.0`
   (`errors`, `filters`, `observability`, `operators`, `ordering`),
   `pagination.yaml` uses `postgrest_version: v16.0`, and `url_grammar.md`
   states it in prose ("Version pinned: **PostgREST v16.0**"). Do not grep for
   a single spelling.

2. **Conformance cases** — 620 YAML files under `conformance/cases/`. Each is one
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

Two request shapes are supported:

- **HTTP** (the common case, 582 cases): `request.method` + `request.path`, with
  optional `request.headers` / `request.body` / `request.body_raw`. The **auth**
  area may add `request.jwt` to have the runner mint and send a signed token
  (32 cases do; case 11809 instead spells out a literal `Authorization` header,
  because it needs a token signed with a secret the harness does not know).
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
request header, so the label must name a schema the conformance server exposes.
Several labels resolve through aliases (`unicode` → `تست`, `multi` → the
`v1`/`v2` profile pair).

Ownership rules for everything under `conformance/fixtures/` — who may write
which file, and why `<area>.delta.sql` is the only write channel — are in
[`conformance/fixtures/README.md`](conformance/fixtures/README.md). All five
`*.delta.sql` files are currently **comment-only** — each holds a single
`-- Folded into ../fixtures.sql on 2026-08-08 (…); empty until the next delta.`
provenance line and no DDL, i.e. empty as a write channel.

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

All **620** cases currently parse and validate, with **no duplicate ids** (and
every `NNNN_` filename prefix equals the in-file `id:`).

## Review status

Citations are **self-reported**: every case carries a pinned `source:` URL with
a line anchor. The v16.0 re-sync's adversarial review — re-fetching the cited
line and confirming it still asserts what the case claims — is summarized
per area in [`COVERAGE.md`](COVERAGE.md), together with the open gaps and the
machine-verification results for this pass.

Three areas carry a recorded v16.0 adversarial verdict so far — **auth**,
**headers** and **config**, all three ⚠️ *revise* with **zero citation
defects** (every finding is a missing-coverage gap, now itemized in
`COVERAGE.md` → *Known gaps*). The other **14** areas have not been re-audited
at this pin; run `bier-spec-audit` over them before treating their citations as
verified.
