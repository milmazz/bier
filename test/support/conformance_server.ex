defmodule Bier.ConformanceServer do
  @moduledoc """
  Boots the shared Bier instances for the conformance suite and exposes their
  base URLs. Started in test_helper.exs before ExUnit.start/1.

  Two shared instances differing only in auth configuration:

    * `bulk` (`base_opts/0`) — no `jwt_secret`/`db_anon_role`/`db_pre_request`,
      so `Bier.Auth.applicable?/1` is false and requests run as the connecting
      superuser. Serves the non-auth areas (byte-identical to the pre-split
      single instance, whose auth context was gated to the `auth` schema).
    * `auth` (`auth_opts/0`) — bulk plus the three auth settings, so role
      switching + request GUCs + the `auth.switch_role` pre-request hook apply.
      Serves the cases that need auth: `schema in ["auth","openapi"]` or the
      root document (`path == "/"`, which resolves the anon role to filter the
      OpenAPI doc but never switches the DB role).

  The shared fixture DB connects as a superuser and grants
  `postgrest_test_anonymous` almost nothing, so role-switching in the bulk
  areas would 42501; keeping auth off the bulk instance preserves current
  behavior. This split is the harness's half of PR 1 (the library half makes
  `applicable?/1` faithful to PostgREST).
  """

  @bulk_instance __MODULE__.Instance
  @auth_instance __MODULE__.AuthInstance
  @bulk_key {__MODULE__, :base_url}
  @auth_key {__MODULE__, :auth_url}

  @doc "Start both shared instances on free ports and remember their base URLs."
  def start! do
    if :persistent_term.get(@bulk_key, nil) != nil do
      raise "ConformanceServer.start!/0 called more than once — call it only from test_helper.exs"
    end

    base = start_instance(@bulk_instance, base_opts())
    :persistent_term.put(@bulk_key, base)

    auth = start_instance(@auth_instance, auth_opts())
    :persistent_term.put(@auth_key, auth)

    start_variants()
    base
  end

  @doc "Base URL of the no-auth (bulk) shared instance."
  def base_url, do: :persistent_term.get(@bulk_key)

  @doc "Base URL of the auth-configured shared instance."
  def auth_url, do: :persistent_term.get(@auth_key)

  @doc """
  Base URL to send a case to: a dedicated variant instance for cases carrying a
  per-case `config:` block, else the `auth` instance for auth-needing cases
  (`schema in ["auth","openapi"]` or the root document), else the `bulk`
  instance.
  """
  @variant_case_ids [1467, 1468, 1469, 1470, 1471, 1472, 1473] ++
                      [1491, 1493, 1654, 1677, 1678, 1680, 1682, 1703, 1758, 1763, 1764]

  def url_for(%Bier.ConformanceCase{id: id}) when id in @variant_case_ids,
    do: :persistent_term.get({__MODULE__, :variant, id})

  def url_for(%Bier.ConformanceCase{} = case_data) do
    if auth_case?(case_data), do: auth_url(), else: base_url()
  end

  # A case needs the auth instance when it targets the auth or openapi profile,
  # or hits the root document (which resolves the anon role to filter the doc).
  defp auth_case?(%Bier.ConformanceCase{schema: schema, request: request}),
    do: schema in ["auth", "openapi"] or Map.get(request, "path") == "/"

  # One Bier instance per variant case. The set is tiny, so they are started
  # eagerly here rather than lazily (which would race under `async: true`). Each
  # variant rebases onto the auth or bulk opts via the same predicate.
  defp start_variants do
    Bier.ConformanceCase.load_all()
    |> Enum.filter(&(&1.id in @variant_case_ids))
    |> Enum.each(fn %Bier.ConformanceCase{id: id, config: config} = case_data ->
      name = Module.concat(__MODULE__, "Variant#{id}")

      variant_base = if auth_case?(case_data), do: auth_opts(), else: base_opts()

      opts =
        variant_base
        # Each variant serves a single low-traffic case, so a small pool keeps
        # the combined connection count of all instances under Postgres'
        # max_connections.
        |> Keyword.merge(pool_size: 2)
        |> Keyword.merge(translate(config))
        |> Keyword.merge(variant_extra_opts(id))

      base = start_instance(name, opts)
      :persistent_term.put({__MODULE__, :variant, id}, base)
    end)
  end

  # Case 1654 asserts the default title/description when the exposed schema has
  # no COMMENT; expose a comment-less schema so the shared "test" schema (which
  # has a comment needed by case 1656) is not affected.
  defp variant_extra_opts(1654), do: [db_schemas: ["openapi_no_comment"]]
  # Case 1764 asserts the no-JWT-secret 500 path (PGRST300); its instance must
  # run without a secret even though auth_opts configures one (db_anon_role
  # keeps auth applicable so resolve/JWT runs and yields PGRST300).
  defp variant_extra_opts(1764), do: [jwt_secret: nil]
  defp variant_extra_opts(_id), do: []

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
  # `log-level` is an enum atom in the config schema, so its YAML scalar (e.g.
  # "error") is converted from string to atom.
  defp translate(config) do
    Enum.map(config, fn
      {"db-schemas", v} when is_binary(v) -> {:db_schemas, [v]}
      {"log-level", v} when is_binary(v) -> {:log_level, String.to_atom(v)}
      {k, v} -> {k |> String.replace("-", "_") |> String.to_atom(), resolve(v)}
    end)
  end

  defp resolve("asymmetric_jwk_public_key"), do: @asymmetric_jwk_public_key
  defp resolve(value), do: value

  @doc """
  No-auth ("bulk") `Bier.start_link/1` options for the conformance suite.

  This is the former shared `base_opts` minus the three auth settings
  (`jwt_secret`, `db_anon_role`, `db_pre_request`), which now live in
  `auth_opts/0`. Kept public and auth-free so the existing `test/bier/*` unit
  tests that boot instances from it stay superuser (unchanged). Connection
  params come from the standard `PG*` environment variables (set by CI),
  defaulting to a local `bier_test`.
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
      jwt_aud: nil,
      server_cors_allowed_origins: "http://example.com, http://example2.com",
      # Observability: the shared instances keep these enabled (the majority of
      # the cases assert their presence). 1758/1763 need the opposite and are
      # handled by the per-case variant instances.
      server_timing_enabled: true,
      server_trace_header: "X-Request-Id",
      log_level: :error
    ]
  end

  @doc """
  Auth-configured options: `base_opts/0` plus the JWT secret, anon role, and
  pre-request hook. Used by the shared `auth` instance and by any variant whose
  case needs auth.
  """
  def auth_opts do
    base_opts() ++
      [
        db_anon_role: "postgrest_test_anonymous",
        # db-pre-request hook: runs inside the auth request transaction.
        db_pre_request: "auth.switch_role",
        # HS256 secret matching PostgREST's testCfg default (>= 32 chars).
        jwt_secret: "reallyreallyreallyreallyverysafe"
      ]
  end
end
