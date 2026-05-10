---
name: Spec gap
about: A test contradicts observed PostgREST behavior — open this before changing the test.
title: "spec-gap: <feature> — <one-line summary>"
labels: ["spec-gap", "needs-researcher"]
assignees: []
---

<!--
Per docs/AGENT_PLAN.md §7.1, a Developer who finds a test that
contradicts PostgREST does NOT edit the test. They mark their PR Draft,
file this issue, and move on. The Researcher verifies, updates spec/,
and the Tester regenerates the affected tests.
-->

## Failing test ID

<!-- The conformance case ID (e.g. "0042") and/or ExUnit test name. -->

## Observed PostgREST behavior

<!-- Exactly what PostgREST does. Paste the request and the response. -->

```http
GET /people?or=(age.gte.14,age.lte.18) HTTP/1.1
Accept: application/json
```

```http
HTTP/1.1 200 OK
Content-Type: application/json; charset=utf-8

[ ... ]
```

## Source URL

<!--
Required. A permalink to the PostgREST source/docs/test that
demonstrates the behavior. Use a `vX.Y.Z` tag, not `main`, so the
reference does not rot. The Researcher refuses untraceable spec
entries (§12 risk: "Agents hallucinate PostgREST behavior").
-->

- PostgREST version pinned: <!-- e.g. v12.2.0 -->
- Source: <!-- e.g. https://github.com/PostgREST/postgrest/blob/v12.2.0/test/spec/Feature/Query/AndOrSpec.hs#L117 -->

## Minimal reproduction

<!--
Smallest fixture + request that triggers the divergence. If you can
express the fixture as SQL fitting under spec/conformance/fixtures.sql,
do that. Otherwise describe the schema you need.
-->

```sql
-- fixture
```

```
-- request
```

```
-- expected response (PostgREST)
```

```
-- actual response (Bier)
```

## Spec section affected

<!--
Which spec/*.yaml or spec/*.md will the Researcher need to edit?
e.g. spec/filters.yaml, spec/operators.yaml.
-->

## Notes

<!-- Anything else the Researcher needs. -->
