import Config

# Conformance test configuration. The fixture DB is `bier_test`, loaded by
# `mix bier.fixtures.load` (wired into the `mix test` alias). The connecting
# user is the local superuser so role-switching and grants are sidestepped in
# the foundation.

config :bier,
  hostname: "localhost",
  port: 5432,
  database: "bier_test",
  username: System.get_env("PGUSER") || System.get_env("USER") || "postgres",
  password: System.get_env("PGPASSWORD"),
  pool_size: 10,
  # Ordered list of every exposed schema. The FIRST element ("test") is the
  # default schema used when a request carries no Accept-Profile header.
  db_schemas: [
    "test",
    "operators",
    "ordering",
    "pagination",
    "representations",
    "mutations",
    "rpc",
    "headers",
    "config",
    "openapi",
    "domain_representations",
    "observability",
    "v1",
    "v2",
    "SPECIAL \"@/\\#~_-",
    # Unicode schema (UnicodeSpec). Exposed so introspection picks up its
    # relation موارد; reached via the `unicode` profile-label alias below.
    "تست"
  ],
  # Profile-label aliases the conformance harness sends as Accept-Profile but
  # which are not themselves exposed schemas. `unicode` is the UnicodeSpec
  # label whose data lives in the schema تست.
  db_schema_aliases: %{"unicode" => "تست"},
  # Multi-schema profile routing for the "headers" area (MultipleSchemaSpec).
  # PostgREST exposes v1/v2/SPECIAL with v1 as the default. The conformance
  # harness wraps every `schema: headers` case in `Accept-Profile: headers`, so
  # the area label `headers` is the default profile and must resolve to v1 (and
  # be echoed as `v1` in Content-Profile). `db_profile_default` names the schema
  # whose relations a default-profile request resolves to and whose name is
  # echoed; `db_profile_schemas` is the exposure-ordered list reported in the
  # PGRST106 hint when an unknown profile is requested.
  db_profile_default: "v1",
  db_profile_schemas: ["v1", "v2", "SPECIAL \"@/\\#~_-"],
  db_anon_role: "postgrest_test_anonymous",
  db_extra_search_path: ["public"],
  db_max_rows: nil,
  # The config-area db-max-rows cases (1700/1701) require a cap of 2 rows, but
  # only for the `config` schema — every other area needs uncapped reads on the
  # same shared instance. A per-schema override pins db-max-rows=2 for `config`.
  db_max_rows_by_schema: %{"config" => 2},
  db_plan_enabled: true,
  # Roll every request's transaction back after the response is computed. The
  # conformance suite runs async against ONE shared fixture DB whose per-area
  # profile schemas are auto-updatable views over the same `test.*` base tables;
  # committing writes would let a mutation in one test contaminate concurrent
  # reads in another (order-dependent flakiness). Rollback keeps the DB pristine
  # while leaving each case's own response unchanged. (PostgREST db-tx-end.)
  db_tx_end: :rollback,
  # pg-safeupdate parity: these tables reject a filterless UPDATE/DELETE with
  # SQLSTATE 21000 (mutations safe-update/safe-delete cases).
  db_safe_update_tables: ["safe_update_items", "safe_delete_items"],
  jwt_secret: nil,
  # CORS (PostgREST server-cors-allowed-origins). The config-area cases pin a
  # fixed allowlist: an Origin in the list is echoed with credentials (1702),
  # one outside it gets no Access-Control-Allow-Origin header (1704). CORS
  # headers are only emitted when a request carries an Origin, so this is inert
  # for every other area.
  server_cors_allowed_origins: "http://example.com, http://example2.com",
  # Observability (PostgREST server-timing-enabled / server-trace-header /
  # log-level). The conformance suite boots ONE shared instance, so a single
  # fixed config must cover the observability cases. The majority assert the
  # Server-Timing header is PRESENT (1750-1757, 1759) and the trace header is
  # echoed (1760-1762), so both are enabled here. The two cases that require the
  # OPPOSITE (1758 server-timing disabled, 1763 trace-header unset) cannot be
  # satisfied under the same fixed config and are expected to fail.
  server_timing_enabled: true,
  server_trace_header: "X-Request-Id",
  log_level: :error
