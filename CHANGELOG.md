# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

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
