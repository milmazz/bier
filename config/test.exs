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
    "v2"
  ],
  db_anon_role: "postgrest_test_anonymous",
  db_extra_search_path: ["public"],
  db_max_rows: nil,
  db_plan_enabled: true,
  jwt_secret: nil
