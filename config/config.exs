import Config

# The ONLY config this library keeps. Every `:bier` setting now lives in the
# test harness (`Bier.ConformanceServer.base_opts/0`), per Elixir library
# guidelines: a library should not configure itself via `config/` — it reads
# from application env at runtime so host apps configure it.
#
# This single entry must stay here because it is COMPILE-TIME. The conformance
# suite exercises `RAISE ... PT...` errors that return a non-standard HTTP
# status (332, e.g. cases 1508/1509). Bandit/Plug resolve a status's reason
# phrase via `Plug.Conn.Status`, whose map is compiled from `config :plug,
# :statuses` — there is no runtime way to register a custom status. (Not shipped
# in the hex package; only used when compiling this library's own suite.)
config :plug, :statuses, %{332 => "Custom Status"}
