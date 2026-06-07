import Config

# Runtime configuration. Reads DATABASE_URL / PGRST_* environment variables so
# the `config` conformance area (which exercises config sources/aliases) and
# real deployments can override connection and PostgREST settings without a
# recompile.

if database_url = System.get_env("DATABASE_URL") do
  %URI{host: host, port: port, path: path, userinfo: userinfo} = URI.parse(database_url)

  {username, password} =
    case userinfo do
      nil -> {nil, nil}
      info -> info |> String.split(":", parts: 2) |> then(&{Enum.at(&1, 0), Enum.at(&1, 1)})
    end

  database = path && String.trim_leading(path, "/")

  config :bier,
    hostname: host || "localhost",
    port: port || 5432,
    database: database,
    username: username,
    password: password
end

# PostgREST-parity environment overrides (PGRST_*).
pgrst = fn key, default ->
  case System.get_env(key) do
    nil -> default
    "" -> default
    value -> value
  end
end

if schemas = System.get_env("PGRST_DB_SCHEMAS") do
  config :bier, db_schemas: schemas |> String.split(",") |> Enum.map(&String.trim/1)
end

config :bier,
  db_anon_role: pgrst.("PGRST_DB_ANON_ROLE", Application.get_env(:bier, :db_anon_role)),
  jwt_secret: pgrst.("PGRST_JWT_SECRET", Application.get_env(:bier, :jwt_secret))

if max_rows = System.get_env("PGRST_DB_MAX_ROWS") do
  config :bier, db_max_rows: String.to_integer(max_rows)
end

# QueryParser leaf-grammar backend: `:regex` (default) or `:nimble`
# (the experimental nimble_parsec twins). Used to prove behavior-equivalence of
# the two backends against the conformance suite. See `bench/REPORT.md`.
case System.get_env("BIER_PARSER_BACKEND") do
  "nimble" -> config :bier, parser_backend: :nimble
  "regex" -> config :bier, parser_backend: :regex
  _ -> :ok
end
