import Config

# Shared defaults for every Bier instance. Because the conformance harness boots
# a Bier instance passing only `:name` and `:router`, all DB/PostgREST settings
# must be sourced from application env (see config/test.exs and config/runtime.exs).

config :bier,
  # Connection parameters for the per-instance Postgrex pool.
  hostname: "localhost",
  port: 5432,
  database: "bier",
  username: System.get_env("USER") || "postgres",
  password: nil,
  pool_size: 10,
  # `db_schemas` is an *ordered* list of exposed schemas; the FIRST element is
  # the default schema used when no Accept-Profile/Content-Profile is given.
  db_schemas: ["public"],
  db_anon_role: "postgrest_test_anonymous",
  db_extra_search_path: ["public"],
  db_max_rows: nil,
  jwt_secret: nil,
  server_cors_allowed_origins: nil

import_config "#{config_env()}.exs"
