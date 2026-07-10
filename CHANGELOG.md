# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

- `application/geo+json` broadened from relation reads to also cover
  mutations (with `Prefer: return=representation`), `/rpc/*`, and embedded
  reads, whenever the PostGIS extension is installed (#63).
- **Behavior note:** response bodies are now byte-identical to PostgREST
  v14.12, including its `, \n ` row separator between top-level JSON array
  elements and jsonb-styled embed internals — this shifts `Content-Length` on
  any multi-row response compared to earlier Bier versions (#31).

Nothing has been published to Hex yet. Current state of the library:

- RESTful API generated at boot from PostgreSQL introspection (`pg_catalog`),
  heavily inspired by [PostgREST](https://postgrest.org) and driven by a
  conformance suite frozen from PostgREST v14.12.
- Reads, mutations (insert/update/upsert/delete), and `/rpc/*` function calls
  compiled into a single parameterized SQL statement per request.
- JWT authentication (HS/RS/ES/PS/EdDSA via JOSE) with role switching and
  request-scoped GUCs.
- Schema-cache reload via `LISTEN`/`NOTIFY` and `Bier.reload_schema_cache/1`.
- Multiple named instances per BEAM node, each with its own connection pool,
  runtime-built router, and Bandit server.
- Standalone PostgREST-compatible CLI (`PGRST_*` env), `mix release` target,
  and Dockerfile.
