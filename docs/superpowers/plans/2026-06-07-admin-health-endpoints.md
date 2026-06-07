# Admin health endpoints (`/live`, `/ready`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in, per-instance admin HTTP server exposing `GET /live` and `GET /ready`, plus the `admin-server-port` ≠ `server-port` validation (issue #30).

**Architecture:** Each `Bier` supervisor instance optionally starts a second Bandit listener (bound to `admin_server_port`) serving a dedicated minimal plug `Bier.Plugs.AdminRouter` — separate from the catch-all API router so root URLs stay PostgREST-compatible. `/live` is pure liveness; `/ready` delegates to `Bier.Health.ready?/1`, which checks the instance's schema cache (`:persistent_term`) and pings its Postgrex pool.

**Tech Stack:** Elixir 1.19 / OTP 28, Plug, Bandit, Postgrex, NimbleOptions, ExUnit, Req (test HTTP client).

---

## File structure

- **Modify** `lib/bier.ex` — add `admin_server_port` to the options schema; start the admin Bandit listener in `init/1` when the port is set.
- **Modify** `lib/bier/config.ex` — add `admin_server_port` to the struct + typespec; cross-field validation in `new!/2`.
- **Create** `lib/bier/health.ex` — `Bier.Health.ready?/1` (schema-cache + DB-ping check).
- **Create** `lib/bier/plugs/admin_router.ex` — `Bier.Plugs.AdminRouter` plug (`/live`, `/ready`, 404 fallthrough).
- **Create** `test/bier/health_test.exs` — unit test for the cache-absent readiness path.
- **Create** `test/bier/plugs/admin_router_test.exs` — unit tests for the plug (`/live` 200, `/ready` 503 when not ready, 404).
- **Create** `test/bier/admin_server_test.exs` — integration test: boot an instance with an admin port, hit `/live` and `/ready` over HTTP.
- **Modify** `test/bier_test.exs` — config validation unit tests (admin == server port rejected).
- **Modify** `spec/COVERAGE.md` — update the `admin_server` note.

---

## Task 1: Config — `admin_server_port` field + cross-field validation

**Files:**
- Modify: `lib/bier.ex` (schema list, end of `schema/0`)
- Modify: `lib/bier/config.ex` (typespec, `defstruct`, `new!/2`)
- Test: `test/bier_test.exs`

- [ ] **Step 1: Write the failing tests**

Replace the contents of `test/bier_test.exs` with:

```elixir
defmodule BierTest do
  use ExUnit.Case, async: true

  describe "Bier.Config.new!/2 admin-server-port validation" do
    defp opts(extra), do: [name: :"admin_cfg_#{System.unique_integer([:positive])}"] ++ extra

    test "rejects admin_server_port equal to the router port" do
      assert_raise ArgumentError, ~r/admin-server-port cannot be the same as server-port/, fn ->
        Bier.Config.new!(
          opts(router: [port: 3000, scheme: :http], admin_server_port: 3000),
          Bier.schema()
        )
      end
    end

    test "accepts admin_server_port that differs from the router port" do
      conf =
        Bier.Config.new!(
          opts(router: [port: 3000, scheme: :http], admin_server_port: 3001),
          Bier.schema()
        )

      assert conf.admin_server_port == 3001
    end

    test "accepts a nil admin_server_port (default, admin server disabled)" do
      conf = Bier.Config.new!(opts(router: [port: 3000, scheme: :http]), Bier.schema())
      assert conf.admin_server_port == nil
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/bier_test.exs`
Expected: FAIL — `admin_server_port` is not yet a known option / not on the struct (e.g. `NimbleOptions` "unknown options" or `KeyError`).

- [ ] **Step 3: Add the schema option**

In `lib/bier.ex`, inside `schema/0`, add this entry immediately after the `db_root_spec:` entry (before the closing `]` of the list):

```elixir
      ],
      admin_server_port: [
        type: {:or, [:pos_integer, nil]},
        default: env(:admin_server_port, nil),
        doc: """
        TCP port for the per-instance admin server exposing the `/live` and
        `/ready` health endpoints (PostgREST admin-server-port). When `nil`
        (the default) no admin server starts. Must differ from `router[:port]`.
        """
      ]
    ]
  end
```

(Note: the snippet shows the `db_root_spec` entry's closing `],` followed by the new entry and the list/`schema/0` close. Adjust to match the existing closing punctuation — append a `,` after the `db_root_spec` entry's `]` and insert the new entry.)

- [ ] **Step 4: Add the struct field + typespec**

In `lib/bier/config.ex`, add to the `@type t` map (after `db_root_spec: String.t() | nil`):

```elixir
          db_root_spec: String.t() | nil,
          admin_server_port: pos_integer() | nil
        }
```

And add `:admin_server_port` to `defstruct` (it defaults to `nil`, so add it to the leading list of bare atoms, e.g. next to `:db_root_spec`):

```elixir
    :db_root_spec,
    :admin_server_port,
```

- [ ] **Step 5: Add cross-field validation in `new!/2`**

In `lib/bier/config.ex`, replace `new!/2` with:

```elixir
  @spec new!(Keyword.t(), Keyword.t()) :: t() | no_return()
  def new!(opts, schema) do
    conf = NimbleOptions.validate!(opts, schema)

    validate_admin_server_port!(conf)

    struct!(__MODULE__, conf)
  end

  # PostgREST rejects an admin-server-port equal to server-port at startup
  # (test_cli.py:test_server_port_and_admin_port_same_value; conformance case
  # 1717). NimbleOptions validates fields independently, so this cross-field
  # check lives here.
  defp validate_admin_server_port!(conf) do
    admin_port = conf[:admin_server_port]
    server_port = get_in(conf, [:router, :port])

    if not is_nil(admin_port) and admin_port == server_port do
      raise ArgumentError, "admin-server-port cannot be the same as server-port"
    end
  end
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mix test test/bier_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 7: Commit**

```bash
git add lib/bier.ex lib/bier/config.ex test/bier_test.exs
git commit -m "feat(#30): admin_server_port config + server-port collision validation"
```

---

## Task 2: `Bier.Health` readiness check

**Files:**
- Create: `lib/bier/health.ex`
- Test: `test/bier/health_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/bier/health_test.exs`:

```elixir
defmodule Bier.HealthTest do
  use ExUnit.Case, async: true

  describe "ready?/1" do
    test "is false when the schema cache is absent (no DB ping needed)" do
      # An instance name that was never booted has no :persistent_term relations
      # entry and no Postgrex pool. ready?/1 must short-circuit to false on the
      # empty cache without raising on the missing pool.
      name = :"never_booted_#{System.unique_integer([:positive])}"
      refute Bier.Health.ready?(name)
    end

    test "is false when the schema cache is present but empty" do
      name = :"empty_cache_#{System.unique_integer([:positive])}"
      :persistent_term.put({Bier, :relations, name}, %{})
      on_exit(fn -> :persistent_term.erase({Bier, :relations, name}) end)
      refute Bier.Health.ready?(name)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/bier/health_test.exs`
Expected: FAIL — `Bier.Health` is undefined.

- [ ] **Step 3: Implement `Bier.Health`**

Create `lib/bier/health.ex`:

```elixir
defmodule Bier.Health do
  @moduledoc """
  Health checks backing the per-instance admin endpoints.

  `ready?/1` reports whether a named `Bier` instance can serve requests: its
  schema cache must be populated AND its Postgrex pool must answer a trivial
  query. The schema-cache check runs first and short-circuits, so a name with no
  cache returns `false` without touching (a possibly absent) connection pool.
  """

  alias Bier.Registry

  @doc """
  Returns `true` when the instance `name` is ready to serve requests:
  the schema cache is populated and the database answers `SELECT 1`.
  """
  @spec ready?(Bier.name()) :: boolean()
  def ready?(name) do
    schema_cache_populated?(name) and database_responsive?(name)
  end

  defp schema_cache_populated?(name) do
    map_size(:persistent_term.get({Bier, :relations, name}, %{})) > 0
  end

  defp database_responsive?(name) do
    case Postgrex.query(Registry.via(name, Postgrex), "SELECT 1", []) do
      {:ok, _result} -> true
      {:error, _reason} -> false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/bier/health_test.exs`
Expected: PASS (2 tests). The empty/absent cache short-circuits before the pool lookup.

- [ ] **Step 5: Commit**

```bash
git add lib/bier/health.ex test/bier/health_test.exs
git commit -m "feat(#30): Bier.Health.ready?/1 schema-cache + DB-ping check"
```

---

## Task 3: `Bier.Plugs.AdminRouter` plug

**Files:**
- Create: `lib/bier/plugs/admin_router.ex`
- Test: `test/bier/plugs/admin_router_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/bier/plugs/admin_router_test.exs`:

```elixir
defmodule Bier.Plugs.AdminRouterTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias Bier.Plugs.AdminRouter

  defp call(method, path, name) do
    conn(method, path)
    |> AdminRouter.call(AdminRouter.init(name: name))
  end

  test "GET /live returns 200 regardless of readiness" do
    name = :"live_#{System.unique_integer([:positive])}"
    conn = call(:get, "/live", name)
    assert conn.status == 200
  end

  test "GET /ready returns 503 when the instance is not ready" do
    # No schema cache for this name -> Bier.Health.ready?/1 is false.
    name = :"notready_#{System.unique_integer([:positive])}"
    conn = call(:get, "/ready", name)
    assert conn.status == 503
  end

  test "unknown paths return 404" do
    name = :"unknown_#{System.unique_integer([:positive])}"
    assert call(:get, "/metrics", name).status == 404
    assert call(:post, "/live", name).status == 404
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/bier/plugs/admin_router_test.exs`
Expected: FAIL — `Bier.Plugs.AdminRouter` is undefined.

- [ ] **Step 3: Implement the plug**

Create `lib/bier/plugs/admin_router.ex`:

```elixir
defmodule Bier.Plugs.AdminRouter do
  @moduledoc """
  Minimal plug for a `Bier` instance's admin server (PostgREST admin server).

  Served on its own Bandit listener bound to `admin_server_port`, kept separate
  from the catch-all API router so the health paths never collide with table
  names. Exposes:

    * `GET /live`  — `200` whenever the process is up (pure liveness).
    * `GET /ready` — `200` when `Bier.Health.ready?/1` holds, else `503`.

  Every other request returns `404`. The instance name is supplied via
  `init/1` (`name:`) so readiness resolves the right pool and schema cache.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: Keyword.fetch!(opts, :name)

  @impl Plug
  def call(%Plug.Conn{method: "GET", path_info: ["live"]} = conn, _name) do
    send_resp(conn, 200, "")
  end

  def call(%Plug.Conn{method: "GET", path_info: ["ready"]} = conn, name) do
    status = if Bier.Health.ready?(name), do: 200, else: 503
    send_resp(conn, status, "")
  end

  def call(conn, _name) do
    send_resp(conn, 404, "")
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/bier/plugs/admin_router_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/bier/plugs/admin_router.ex test/bier/plugs/admin_router_test.exs
git commit -m "feat(#30): Bier.Plugs.AdminRouter with /live and /ready"
```

---

## Task 4: Wire the admin Bandit listener into the supervisor + integration test

**Files:**
- Modify: `lib/bier.ex` (`init/1`)
- Test: `test/bier/admin_server_test.exs`

- [ ] **Step 1: Write the failing integration test**

Create `test/bier/admin_server_test.exs`:

```elixir
defmodule Bier.AdminServerTest do
  @moduledoc """
  Boots a dedicated Bier instance with an admin server against the test DB and
  exercises the health endpoints over HTTP. Not async: it binds real ports and
  runs DB introspection at boot.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  setup do
    api_port = free_port()
    admin_port = free_port()

    opts =
      [
        name: :"admin_it_#{System.unique_integer([:positive])}",
        router: [port: api_port, scheme: :http],
        admin_server_port: admin_port
      ] ++ Bier.ConformanceServer.base_opts()

    start_supervised!({Bier, opts})
    wait_until_listening(admin_port)

    %{admin_port: admin_port}
  end

  test "GET /live returns 200", %{admin_port: admin_port} do
    resp = Req.get!("http://127.0.0.1:#{admin_port}/live", retry: false)
    assert resp.status == 200
  end

  test "GET /ready returns 200 once the schema cache is populated", %{admin_port: admin_port} do
    resp = Req.get!("http://127.0.0.1:#{admin_port}/ready", retry: false)
    assert resp.status == 200
  end

  test "unknown admin paths return 404", %{admin_port: admin_port} do
    resp = Req.get!("http://127.0.0.1:#{admin_port}/nope", retry: false)
    assert resp.status == 404
  end

  defp free_port do
    {:ok, sock} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)
    port
  end

  defp wait_until_listening(port, retries \\ 100) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [], 10) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        :ok

      {:error, _} when retries > 0 ->
        Process.sleep(20)
        wait_until_listening(port, retries - 1)

      {:error, reason} ->
        raise "admin server did not come up on port #{port}: #{inspect(reason)}"
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/bier/admin_server_test.exs`
Expected: FAIL — no admin server is started, so `wait_until_listening/1` raises (nothing binds `admin_port`).

- [ ] **Step 3: Start the admin listener in `init/1`**

In `lib/bier.ex`, change `init/1` so its `children` list appends the admin children, and add the `admin_children/1` helper. Replace the existing `init/1` body's `children = [...]` assignment with one that appends `admin_children(conf)`:

```elixir
  @impl Supervisor
  def init(%Bier.Config{name: name} = conf) do
    children =
      [
        Supervisor.child_spec({Postgrex, postgrex_opts(conf)}, id: {name, Postgrex}),
        {DynamicSupervisor,
         strategy: :one_for_one, name: Registry.via(conf.name, DynamicSupervisor)},
        {Bier.HttpServerStarter, conf}
      ] ++ admin_children(conf)

    Supervisor.init(children, strategy: :one_for_one)
  end

  # When `admin_server_port` is set, run a second Bandit listener serving the
  # admin health endpoints (separate from the API router). Started statically
  # here (it needs no introspection result); `/ready` reports 503 until the
  # schema cache is populated, which is the correct readiness signal.
  defp admin_children(%Bier.Config{admin_server_port: nil}), do: []

  defp admin_children(%Bier.Config{name: name, admin_server_port: port} = conf) do
    [
      Supervisor.child_spec(
        {Bandit,
         scheme: conf.router[:scheme],
         plug: {Bier.Plugs.AdminRouter, name: name},
         port: port,
         http_options: [compress: false]},
        id: {name, :admin_server}
      )
    ]
  end
```

(Keep the existing explanatory comments on the Postgrex/DynamicSupervisor children — only the `children =` assignment shape and the new helper change.)

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/bier/admin_server_test.exs`
Expected: PASS (3 tests). Requires a reachable test DB (same as the conformance suite).

- [ ] **Step 5: Commit**

```bash
git add lib/bier.ex test/bier/admin_server_test.exs
git commit -m "feat(#30): start per-instance admin server when admin_server_port set"
```

---

## Task 5: Documentation + full-suite verification

**Files:**
- Modify: `spec/COVERAGE.md`

- [ ] **Step 1: Update the `admin_server` coverage note**

In `spec/COVERAGE.md`, find the `admin_server` row (currently):

```
| `admin_server` (Admin Server) | 1717 (admin-port = server-port fatal) | Only the port-collision validation. Partial — no `/live` `/ready` health-endpoint case. |
```

Replace its third column with:

```
| `admin_server` (Admin Server) | 1717 (admin-port = server-port fatal) | Port-collision validation (case 1717, library-enforced in `Bier.Config`) plus `/live`/`/ready` covered by ExUnit (`test/bier/admin_server_test.exs`). Partial — case 1717 stays `:pending` (CLI `--dump-config`), `/metrics` not yet implemented. |
```

- [ ] **Step 2: Run the format + compile gates**

Run:
```bash
mix format
mix compile --warnings-as-errors
```
Expected: no errors, no warnings.

- [ ] **Step 3: Run the full suite**

Run: `mix test`
Expected: the 6 pre-existing DB-fixture/auth conformance failures remain (unchanged baseline), and the new tests (Tasks 1–4) all PASS — total failures must not exceed the baseline 6.

- [ ] **Step 4: Commit**

```bash
git add spec/COVERAGE.md
git commit -m "docs(#30): record /live /ready coverage in COVERAGE.md"
```

---

## Self-review

- **Spec coverage:** Config field + default nil (Task 1), admin≠server validation with case-1717 wording (Task 1), separate Bandit listener under the supervisor (Task 4), `/live` 200 (Tasks 3/4), `/ready` DB-ping + schema-cache → 200/503 (Tasks 2/3/4), COVERAGE.md note (Task 5). All design sections map to a task.
- **Placeholder scan:** none — every code/test step shows full content.
- **Type/name consistency:** `Bier.Health.ready?/1`, `Bier.Plugs.AdminRouter.init/1` (`name:`)/`call/2`, `admin_server_port`, cache key `{Bier, :relations, name}`, and `Registry.via(name, Postgrex)` are used identically across tasks and match the existing codebase.
- **Out of scope (unchanged):** `/metrics`, CLI `--dump-config` runner, TLS for the admin listener.
