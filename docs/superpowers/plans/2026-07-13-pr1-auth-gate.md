# PR 1 — PostgREST-faithful auth gate — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Bier's per-request auth context (role switch, `request.*` GUCs, `db-pre-request`) activate whenever auth is configured — for all exposed schemas — exactly like PostgREST, instead of only for a schema literally named `auth`.

**Architecture:** Replace `Bier.Auth.applicable?/1`'s hardcoded `schema == "auth"` with a check on whether auth is configured (`jwt_secret`/`db_anon_role` present). The shared conformance fixture DB (superuser connection, roles ungranted) can't tolerate role-switching in the bulk areas, so the compromise moves entirely into the test harness: split the single shared instance into a no-auth `bulk` instance and an auth-configured `auth` instance, and route each case to the right one.

**Tech Stack:** Elixir, Plug, Postgrex, ExUnit. Conformance suite driven by `spec/conformance/cases/*.yaml`.

## Global Constraints

- Elixir `~> 1.18`; toolchain pinned Elixir 1.20 / OTP 29 (`mise.toml`).
- **Never edit `spec/**`** (frozen ground truth: cases, assertions, `fixtures.sql`). This PR edits only `lib/**` and `test/support/conformance_server.ex`, plus one new additive unit-test file.
- **Do not edit existing `test/bier/*` files** — they are frozen. `base_opts/0` must remain callable and keep them green.
- Acceptance gate: full `mix test` green (`mix test` = `bier.fixtures.load` + `test`; needs a local Postgres). Also `mix format --check-formatted`, `mix credo --strict`, `mix docs --warnings-as-errors`.
- `Bier.json_library/0` for any JSON (not relevant here but repo rule).
- End commit messages with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

## File Structure

- `lib/bier/auth.ex` — change `applicable?/1` (schema → config) + moduledoc.
- `lib/bier/plugs/action_controller.ex` — update the `maybe_auth/3` call site.
- `test/support/conformance_server.ex` — split shared instance into `bulk`/`auth`; add routing predicate; rebase variants.
- `test/bier/auth_applicable_test.exs` — **new**, additive unit test for `applicable?/1`.

This is **one task**: the library change and the harness change cannot be green independently (changing `applicable?` alone turns the whole suite red because the shared instance configures auth globally). They form a single reviewable unit whose gate is the green suite.

---

## Task 1: Gate the auth context on auth being configured, and split the conformance harness

**Files:**
- Modify: `lib/bier/auth.ex` (moduledoc ~22-27; `applicable?/1` at 45-46)
- Modify: `lib/bier/plugs/action_controller.ex:79-88` (`maybe_auth/3`)
- Modify: `test/support/conformance_server.ex` (whole file — see full new content below)
- Create: `test/bier/auth_applicable_test.exs`

**Interfaces:**
- Produces: `Bier.Auth.applicable?(Bier.Config.t()) :: boolean()` — true iff `config.jwt_secret != nil or config.db_anon_role != nil`.
- Produces: `Bier.ConformanceServer.base_opts/0` (no-auth bulk config), `auth_opts/0` (bulk + auth keys), `base_url/0` (bulk instance), `auth_url/0` (auth instance). `url_for/1` unchanged signature.
- Consumes: `Bier.Config` fields `jwt_secret`, `db_anon_role` (both `String.t() | nil`); `Bier.ConformanceCase` fields `schema` (`String.t() | nil`), `request` (map with `"path"`), `id`, `config`.

- [ ] **Step 1: Write the failing unit test**

Create `test/bier/auth_applicable_test.exs`:

```elixir
defmodule Bier.AuthApplicableTest do
  use ExUnit.Case, async: true

  alias Bier.Auth
  alias Bier.ConformanceServer

  defp config(opts) do
    base = [name: :"auth_applicable_#{System.unique_integer([:positive])}"]
    Bier.Config.new!(base ++ opts, Bier.schema())
  end

  test "applicable? is true when a jwt_secret is configured" do
    assert Auth.applicable?(config(jwt_secret: String.duplicate("x", 32)))
  end

  test "applicable? is true when a db_anon_role is configured" do
    assert Auth.applicable?(config(db_anon_role: "web_anon"))
  end

  test "applicable? is false when neither is configured" do
    refute Auth.applicable?(config([]))
  end

  test "base_opts (bulk) has auth disabled; auth_opts enables it" do
    refute Auth.applicable?(config(ConformanceServer.base_opts()))
    assert Auth.applicable?(config(ConformanceServer.auth_opts()))
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/bier/auth_applicable_test.exs`
Expected: FAIL — `Auth.applicable?/1` currently expects a schema string, and `ConformanceServer.auth_opts/0` does not exist yet (compile/UndefinedFunctionError).

- [ ] **Step 3: Change `Bier.Auth.applicable?/1` (library)**

In `lib/bier/auth.ex`, replace the `applicable?/1` clause (lines 41-46):

```elixir
  @doc """
  True when the per-request auth context (role switch + request GUCs +
  pre-request hook) should be applied — i.e. when auth is configured
  (`jwt_secret` or `db_anon_role`). Mirrors PostgREST, where the authenticator
  connects and every request assumes a role whenever auth is set up.
  """
  @spec applicable?(Bier.Config.t()) :: boolean()
  def applicable?(config), do: config.jwt_secret != nil or config.db_anon_role != nil
```

And replace the moduledoc paragraph (lines 22-27, the "Bier applies this context only for requests resolving to the `auth` schema …" block) with:

```elixir
  Bier applies this context whenever auth is configured for the instance
  (`jwt_secret` or `db_anon_role`), for every exposed schema — matching
  PostgREST. When neither is set, requests run as the connecting role with no
  role switch or GUCs. `applicable?/1` encodes that gate.
```

- [ ] **Step 4: Update the call site**

In `lib/bier/plugs/action_controller.ex`, change `maybe_auth/3` (line 79-88) so the gate reads the config, not the schema. The `schema` argument is no longer used by the gate:

```elixir
  @doc false
  def maybe_auth(conn, config, _schema) do
    if Bier.Auth.applicable?(config) do
      case Bier.ServerTiming.measure(:jwt, fn -> Bier.Auth.resolve(conn, config) end) do
        {:ok, context} -> {:ok, assign(conn, :bier_auth, context)}
        {:error, _} = err -> err
      end
    else
      {:ok, conn}
    end
  end
```

(Leave the caller at line 61, `maybe_auth(conn, config, schema)`, unchanged — arity is preserved.)

- [ ] **Step 5: Replace `test/support/conformance_server.ex` with the two-instance version**

Full new file content (only the auth split + routing changes; everything else identical to current):

```elixir
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
```

- [ ] **Step 6: Compile and run the new unit test**

Run: `mix test test/bier/auth_applicable_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 7: Run the full conformance suite (the acceptance gate)**

Run: `mix test`
Expected: PASS, 0 failures. This loads the fixture DB and runs all ~475 active cases across both shared instances plus variants.

If failures appear, they are routing stragglers — expect at most a handful. Diagnose each:
- **`42501` / permission-denied on an `openapi` (or root) case that reads a *relation*** → that case is on the `auth` instance and now switches to `postgrest_test_anonymous`. Fix by narrowing `auth_case?/1` to exclude it (e.g. require the request be a GET of `/`, or special-case that id), NOT by editing `spec/`.
- **`401`/`PGRST300` on a bulk case that unexpectedly hits `/` or sends a token** → route it to the auth instance (widen the predicate for that shape).
- Re-run `mix test` after each predicate tweak until green. Record the final predicate in the moduledoc if it changed.

- [ ] **Step 8: Run the remaining CI gates**

Run: `mix format --check-formatted && mix credo --strict && mix docs --warnings-as-errors`
Expected: all pass. (`mix format` first if needed.)

- [ ] **Step 9: Commit**

```bash
git add lib/bier/auth.ex lib/bier/plugs/action_controller.ex \
        test/support/conformance_server.ex test/bier/auth_applicable_test.exs
git commit -m "feat(auth): gate auth context on config, not schema name

Bier.Auth.applicable? now returns true whenever auth is configured
(jwt_secret or db_anon_role), so role switching, request GUCs, and the
db-pre-request hook apply to every exposed schema — matching PostgREST —
instead of only a schema literally named 'auth'.

The shared conformance fixture DB connects as a superuser and grants the
anon role almost nothing, so role-switching in the bulk areas would 42501.
That compromise moves into the harness: the shared instance splits into a
no-auth 'bulk' instance and an auth-configured 'auth' instance, with cases
routed by schema/path. spec/ is untouched.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

- **Spec coverage:** Part A library change (Step 3-4) ✓; harness two-instance split + routing predicate (Step 5) ✓; unit test (Step 1) ✓; green gate + straggler iteration (Step 7) ✓; format/credo/docs gates (Step 8) ✓; no `spec/` edits (constraints) ✓; `base_opts/0` kept auth-free for frozen `test/bier/*` (Step 5 + rationale) ✓.
- **Placeholders:** none — full file content and exact commands provided.
- **Type consistency:** `applicable?(config)` used identically in Step 3 (def) and Step 4 (call). `base_opts/0`, `auth_opts/0`, `base_url/0`, `auth_url/0`, `auth_case?/1` names consistent across Step 5 and the unit test in Step 1.

## PR

After the commit, open the PR (title: `feat(auth): PostgREST-faithful auth gate`). Body: summarize the library change, the harness split, and the green suite; note that connecting as `authenticator` with role GRANTs (vs superuser) remains future work. The user merges it before PR 2 begins.
