# Boots ONE prod-compiled Bier instance for the HTTP benchmark.
#
#   MIX_ENV=prod mix run --no-halt bench/http/start_bier.exs
#
# Config parity with bench/http/postgrest.conf: pool 10, schema bench,
# anon role bench_anon, no JWT, schema-cache listener off, logging off.
Logger.configure(level: :warning)

port = String.to_integer(System.get_env("BIER_PORT", "3001"))

{:ok, _pid} =
  Bier.start_link(
    name: Bier.Bench,
    router: [port: port, scheme: :http],
    hostname: System.get_env("PGHOST", "localhost"),
    port: String.to_integer(System.get_env("PGPORT", "5432")),
    database: System.get_env("PGDATABASE", "bier_bench"),
    username: System.get_env("PGUSER") || System.get_env("USER") || "postgres",
    password: System.get_env("PGPASSWORD"),
    pool_size: 10,
    db_schemas: ["bench"],
    db_anon_role: "bench_anon",
    db_channel_enabled: false
  )

IO.puts("bier: listening on http://127.0.0.1:#{port}")

# Keep the script's process alive: Bier.start_link/1 links the supervisor to
# this process, and OTP supervisors shut down (silently) when their parent
# exits — --no-halt keeps the VM up but would not keep the tree up.
Process.sleep(:infinity)
