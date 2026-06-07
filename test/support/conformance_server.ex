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

    base = start_instance(@instance, base_opts())
    :persistent_term.put(@key, base)
    start_variants()
    base
  end

  @doc "Base URL of the shared instance (e.g. \"http://127.0.0.1:54321\")."
  def base_url, do: :persistent_term.get(@key)

  @doc """
  Base URL to send a case to: the shared instance, or — for a case carrying a
  per-case `config:` block (PostgREST per-case config) — a dedicated instance
  booted with those overrides merged onto `base_opts/0`.
  """
  # Cases whose `config:` is mutually exclusive with the shared instance's, so
  # they need a dedicated instance. Most config cases are ALREADY satisfied by
  # `base_opts/0` and stay on the shared instance — routing a currently-passing
  # case to a faithful variant could change its result. (openapi-mode/db-root-spec
  # behavior lands separately.) 1467 verifies an RS256 token against an asymmetric
  # public JWK as jwt-secret (issue #23).
  @variant_case_ids [1467, 1491, 1493, 1678, 1682, 1703, 1758, 1763]

  def url_for(%Bier.ConformanceCase{id: id}) when id in @variant_case_ids,
    do: :persistent_term.get({__MODULE__, :variant, id})

  def url_for(%Bier.ConformanceCase{}), do: base_url()

  # One Bier instance per variant case. The set is tiny, so they are started
  # eagerly here rather than lazily (which would race under `async: true`).
  defp start_variants do
    Bier.ConformanceCase.load_all()
    |> Enum.filter(&(&1.id in @variant_case_ids))
    |> Enum.each(fn %{id: id, config: config} ->
      name = Module.concat(__MODULE__, "Variant#{id}")
      base = start_instance(name, Keyword.merge(base_opts(), translate(config)))
      :persistent_term.put({__MODULE__, :variant, id}, base)
    end)
  end

  defp start_instance(name, opts) do
    port = Bier.TestPorts.free_port()
    {:ok, _pid} = Bier.start_link([name: name, router: [port: port, scheme: :http]] ++ opts)
    Bier.TestPorts.wait_until_listening(port)
    "http://127.0.0.1:#{port}"
  end

  # The asymmetric RS256 *public* JWK PostgREST's test suite verifies against
  # (`testCfgAsymJWK` in test/spec/SpecHelper.hs). The spec case carries the
  # symbolic value `asymmetric_jwk_public_key`; the real key lives here in the
  # harness so the case file stays declarative. The matching private key is
  # upstream-only — we only ever verify.
  @asymmetric_jwk_public_key ~s({"alg":"RS256","e":"AQAB","key_ops":["verify"],"kty":"RSA","n":"0etQ2Tg187jb04MWfpuogYGV75IFrQQBxQaGH75eq_FpbkyoLcEpRUEWSbECP2eeFya2yZ9vIO5ScD-lPmovePk4Aa4SzZ8jdjhmAbNykleRPCxMg0481kz6PQhnHRUv3nF5WP479CnObJKqTVdEagVL66oxnX9VhZG9IZA7k0Th5PfKQwrKGyUeTGczpOjaPqbxlunP73j9AfnAt4XCS8epa-n3WGz1j-wfpr_ys57Aq-zBCfqP67UYzNpeI1AoXsJhD9xSDOzvJgFRvc3vm2wjAW4LEMwi48rCplamOpZToIHEPIaPzpveYQwDnB1HFTR1ove9bpKJsHmi-e2uzQ","use":"sig"})

  # Translate a PostgREST per-case `config:` map into `Bier.start_link/1` opts:
  # `kebab-case` keys become the matching snake_case atoms; values pass through
  # as parsed from YAML (`null` -> nil, `false`, `""`, strings), except symbolic
  # placeholders (e.g. the asymmetric JWK) which resolve to their real value.
  # Special case: `db-schemas` in YAML may be a plain scalar string (e.g. "test")
  # when only one schema is listed; wrap it in a list so NimbleOptions accepts it.
  defp translate(config) do
    Enum.map(config, fn
      {"db-schemas", v} when is_binary(v) -> {:db_schemas, [v]}
      {k, v} -> {k |> String.replace("-", "_") |> String.to_atom(), resolve(v)}
    end)
  end

  defp resolve("asymmetric_jwk_public_key"), do: @asymmetric_jwk_public_key
  defp resolve(value), do: value

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
end
