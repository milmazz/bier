# Bier conformance spec

This directory is the **behavioral specification** Bier targets: a black-box,
forge-neutral model of how [PostgREST](https://postgrest.org) responds to HTTP
requests, distilled from PostgREST's own public behavior and test suite.

Bier aims to serve a RESTful API generated on-the-fly from PostgreSQL
introspection, "heavily inspired by PostgREST." This `spec/` tree pins down what
that compatibility means, case by case, so it can be checked automatically.

## Pinned version

Everything here targets **PostgREST v14.12**. Every conformance case carries a
`source:` URL pinned to the `v14.12` git tag with a `#L<line>` anchor, fetchable
via `raw.githubusercontent.com`. When bumping the target version, re-pin the
sources and re-run the review pass.

## What's here

```
spec/
├── README.md                  # this file
├── COVERAGE.md                # docs-page / feature-area -> covering case ids; gaps
├── case.schema.json           # JSON Schema for a single conformance case
├── <area>.yaml | url_grammar.md   # 16 per-area behavior models (the "why")
└── conformance/
    ├── INDEX.md               # area <-> id band <-> fixture cross-reference
    ├── cases/NNNN_<slug>.yaml # 502 conformance cases (the "what", machine-checkable)
    └── fixtures/<area>.sql     # 16 SQL fixture fragments the cases load
```

There are two layers:

1. **Area behavior models** — one file per feature area
   (`url_grammar.md` plus 15 `.yaml` files: `operators`, `select`, `filters`,
   `ordering`, `pagination`, `representations`, `mutations`, `rpc`, `auth`,
   `errors`, `headers`, `content_negotiation`, `openapi`, `config`,
   `observability`). These describe the grammar, defaults, and rules of an area
   in prose/structured form, each claim citing a PostgREST source line. They are
   the human-readable rationale.

2. **Conformance cases** — 502 YAML files under `conformance/cases/`. Each is one
   concrete scenario: a request and the exact response (status, headers, body)
   PostgREST produces. These are the machine-checkable contract.

## Anatomy of a conformance case

Each case validates against [`case.schema.json`](case.schema.json):

```yaml
id: 1200                       # globally-unique; each area owns an id band
feature: ordering/direction/asc  # slash-delimited <area>/<sub-feature>/...
request:
  method: GET                  # HTTP shape: method + path
  path: /items?order=id.asc
  headers: { Accept: application/json }
schema: ordering               # which fixtures/<...>.sql data set to load
preconditions: []              # optional SQL run before the request
expect:
  status: 200
  headers: { Content-Type: "application/json; charset=utf-8" }
  body_exact: [ ... ]          # body_exact | body_jsonpath | body_contains | body_raw
notes: "..."                   # rationale, references the upstream it-block
source: https://raw.githubusercontent.com/PostgREST/postgrest/v14.12/...#L<n>
```

Two request shapes are supported:

- **HTTP** (the common case): `request.method` + `request.path`. The **auth**
  area may add `request.jwt` to have the runner mint and send a signed token.
- **CLI** (config / observability startup behavior): `request.kind: cli` with
  `request.flag: "--dump-config"`, asserting on `expect.exit_code`,
  `expect.dump_contains`, and `expect.stderr_contains`.

Response assertions include `status`/`exit_code`, exact or pattern header
matches (`headers`, `headers_match`, `headers_present`, `headers_absent`,
`headers_absent_in_value`, `headers_no_blank`), and body assertions
(`body_exact`, `body_jsonpath`, `body_contains`, `body_raw`, `body_json`). See
the schema for the authoritative field list and descriptions.

## Fixtures

Each area is backed by one `conformance/fixtures/<area>.sql` fragment. A case's
`schema:` field names the logical data set the runner loads from that fragment
(several logical names — e.g. `test`, `multi`, `unicode` — can live in one
fragment). See [`conformance/INDEX.md`](conformance/INDEX.md) for the full
area ↔ id-band ↔ fixture map.

## How this drives the Phase 2 Tester

This `spec/` tree is the output of Phase 1 (spec research) of the multi-agent
plan. The **Phase 2 Tester** consumes it: its conformance runner loads each
case's fixture, replays the request against a Bier instance, and asserts the
response matches `expect`. The Tester owns the canonical published schema and
the CI lint gate; `case.schema.json` here is the forge-neutral stand-in so cases
can be linted before the Tester phase exists. The area models guide
implementation; the cases are the pass/fail contract.

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

All 502 cases currently validate.

## Review status

Citations are **self-reported**: every case carries a pinned `source:` URL with
a line anchor, but an adversarial review that re-fetches each source and
confirms the cited line still asserts what the case claims has only been run for
**2 of 16 areas** (pagination and auth). The remaining 14 areas are unreviewed.
See [`COVERAGE.md`](COVERAGE.md) for details.
