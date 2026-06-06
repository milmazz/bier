import Config

# Shared defaults for every Bier instance. Because the conformance harness boots
# a Bier instance passing only `:name` and `:router`, all DB/PostgREST settings
# must be sourced from application env (see config/test.exs and config/runtime.exs).

# A `RAISE SQLSTATE 'PGRST'` (or `PTxxx`) can return an arbitrary, non-standard
# HTTP status with a custom reason phrase (PostgREST Error.hs). Bandit looks the
# reason phrase up via `Plug.Conn.Status.reason_phrase/1`, which is compiled
# from this map and raises for any status it does not know. Register the
# non-standard codes the conformance suite exercises so the response can be sent.
config :plug, :statuses, %{
  332 => "Custom Status"
}

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
