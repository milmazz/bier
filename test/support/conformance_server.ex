defmodule Bier.ConformanceServer do
  @moduledoc """
  Boots ONE shared Bier instance for the conformance suite and exposes its
  base URL. Started in test_helper.exs before ExUnit.start/1.
  """

  @instance __MODULE__.Instance
  @key {__MODULE__, :base_url}

  @doc "Start the shared instance on a free port and remember its base URL."
  def start! do
    if :persistent_term.get(@key, nil) != nil do
      raise "ConformanceServer.start!/0 called more than once — call it only from test_helper.exs"
    end

    port = free_port()
    opts = [name: @instance, router: [port: port, scheme: :http]] ++ base_opts()
    {:ok, _pid} = Bier.start_link(opts)
    base = "http://127.0.0.1:#{port}"
    wait_until_listening(port)
    :persistent_term.put(@key, base)
    base
  end

  @doc "Base URL of the shared instance (e.g. \"http://127.0.0.1:54321\")."
  def base_url, do: :persistent_term.get(@key)

  @doc """
  Base `Bier.start_link/1` options for the conformance suite.

  This is the former `config/test.exs` — kept in the test harness rather than the
  library's `config/` (Elixir library guideline: a library should not configure
  itself via `config/`; it reads from application env at runtime for host apps,
  and our suite passes the settings explicitly). Connection params come from the
  standard `PG*` environment variables (set by CI), defaulting to a local
  `bier_test`. `#14`'s per-case-config instances merge overrides onto this.
  """
  def base_opts do
    [
      hostname: "localhost",
      port: 5432,
      database: "bier_test",
      username: System.get_env("PGUSER") || System.get_env("USER") || "postgres",
      password: System.get_env("PGPASSWORD"),
      pool_size: 10,
      # Ordered list of every exposed schema; the FIRST ("test") is the default
      # used when a request carries no Accept-Profile header.
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
        "auth",
        "v1",
        "v2",
        "SPECIAL \"@/\\#~_-",
        "تست"
      ],
      # Profile-label aliases sent as Accept-Profile that are not exposed schemas.
      db_schema_aliases: %{"unicode" => "تست"},
      # Multi-schema profile routing for the "headers" area: default profile
      # resolves to v1 and is echoed as v1; the list seeds the PGRST106 hint.
      db_profile_default: "v1",
      db_profile_schemas: ["v1", "v2", "SPECIAL \"@/\\#~_-"],
      db_anon_role: "postgrest_test_anonymous",
      db_extra_search_path: ["public"],
      db_max_rows: nil,
      # db-max-rows=2 only for the `config` schema (cases 1700/1701); other areas
      # need uncapped reads on the same shared instance.
      db_max_rows_by_schema: %{"config" => 2},
      db_plan_enabled: true,
      # Roll each request's transaction back after the response is computed, so
      # async tests on the shared fixture DB don't contaminate each other.
      db_tx_end: :rollback,
      db_safe_update_tables: ["safe_update_items", "safe_delete_items"],
      # db-pre-request hook: runs inside the auth-schema request transaction.
      db_pre_request: "auth.switch_role",
      # HS256 secret matching PostgREST's testCfg default (>= 32 chars).
      jwt_secret: "reallyreallyreallyreallyverysafe",
      jwt_aud: nil,
      server_cors_allowed_origins: "http://example.com, http://example2.com",
      # Observability: the shared instance keeps these enabled (the majority of
      # the cases assert their presence). 1758/1763 need the opposite and are
      # handled by #14's per-case instances.
      server_timing_enabled: true,
      server_trace_header: "X-Request-Id",
      log_level: :error
    ]
  end

  defp free_port do
    {:ok, sock} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(sock)
    # TOCTOU: tiny window between closing this probe socket and Bandit binding.
    # Acceptable for a single suite run; avoid parallel suite runs on one host.
    :gen_tcp.close(sock)
    port
  end

  defp wait_until_listening(port, retries \\ 100) do
    # Each attempt: up to ~10ms connect + 20ms sleep ≈ 30ms; 100 retries ≈ 3s ceiling.
    case :gen_tcp.connect(~c"127.0.0.1", port, [], 10) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        :ok

      {:error, _} when retries > 0 ->
        Process.sleep(20)
        wait_until_listening(port, retries - 1)

      {:error, reason} ->
        raise "Bier conformance server did not come up on port #{port}: #{inspect(reason)}"
    end
  end
end
