# Schema-Cache Reload via LISTEN/NOTIFY Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close issue #29 — reload Bier's schema cache on `NOTIFY <db-channel>, 'reload schema'` (PostgREST's `db-channel` listener) and via a programmatic `Bier.reload_schema_cache/1`, without restarting the instance.

**Architecture:** The introspection snapshot moves from four `:persistent_term` keys into one `%Bier.SchemaCache{}` struct under `{Bier, :schema_cache, name}` so a reload is a single atomic swap (the catch-all router needs no rebuild — `Bier.RouterBuilder.build/2` ignores its relations argument). A new `Bier.SchemaCacheListener` GenServer — a config-gated static child of the `Bier` supervisor — owns a dedicated `Postgrex.Notifications` connection, reconnects with internal exponential backoff (never crash-loops the supervisor), coalesces NOTIFY bursts, and reloads unconditionally after every re-LISTEN to cover missed signals. Full design: `docs/superpowers/specs/2026-07-03-schema-cache-reload-design.md`.

**Tech Stack:** Elixir (~> 1.18; dev pinned 1.19.5/OTP 28 in `mise.toml`), Postgrex 0.22 (`Postgrex.Notifications` — already a runtime dep, **no new deps**), NimbleOptions config schema, `:telemetry`, ExUnit + Req against a local PostgreSQL fixture DB.

## Global Constraints

- **Frozen ground truth — never edit:** `test/support/**`, `test/conformance/**`, `spec/**`, `docs/CONFORMANCE_IMPL.md`. All new tests go in **new files** under `test/bier/` (precedent: `test/bier/admin_server_test.exs`). `test/bier/health_test.exs` writes the old `{Bier, :relations, name}` key but only asserts `refute ready?` — it keeps passing untouched; do not edit it.
- **Do not edit** `lib/bier/query_parser.ex` (generated) — not touched by this plan anyway.
- `mix test` requires a reachable local PostgreSQL: it is aliased to `["bier.fixtures.load", "test"]` and drops/recreates the `bier_test` DB first. The full suite is the regression net — **no new failures** after every task. **The baseline is NOT zero:** `681 tests, 3 failures` — geojson conformance cases 1616/1617/1618 need a PostGIS `test.shops` table whose fixture block is deliberately commented out (`spec/conformance/fixtures/content_negotiation.sql`), and CI has the same 3 failures on every PG matrix leg (its workflow gates on `BASELINE_FAILURES` in `.github/workflows/elixir.yml`, red only if failures *increase*). Any 4th failure is a real regression.
- Run `mix format` before every commit. The final gate is the `mix precommit` chain (`deps.unlock --check-unused`, `format --check-formatted`, `hex.audit`, `compile --warnings-as-errors`, `credo --strict`, `docs --warnings-as-errors`, `test`) — but the alias itself **cannot pass**: its `test` step exits non-zero at the 3-failure baseline. Run the gates individually (Task 7 Step 4) and treat exactly 3 test failures as pass. `hex.audit` needs network access to hex.pm; if it fails offline, note it — CI runs them all.
- Config defaults (owner decisions, verbatim): `db_channel` default `"pgrst"`; `db_channel_enabled` default **`true`**; `'reload config'` payload is a **logged no-op**.
- All instance-scoped processes register through `Bier.Registry.via/3`. Per-instance state never goes in `Bier.Application`.
- Integration tests must use a **unique NOTIFY channel per instance** (never `"pgrst"`): the shared conformance instance listens on `"pgrst"` by default after this change.
- Commit message style: `feat(#29): …` / `refactor(#29): …` / `docs(#29): …` (matches `git log`).

---

### Task 1: `Bier.SchemaCache` snapshot module (struct + accessors)

**Files:**
- Create: `lib/bier/schema_cache.ex`
- Test: `test/bier/schema_cache_test.exs` (new file)

**Interfaces:**
- Consumes: nothing (pure new module).
- Produces (later tasks depend on these exact names):
  - `%Bier.SchemaCache{relations: map(), functions: map(), media_handlers: list(), schema_comment: String.t() | nil}`
  - `Bier.SchemaCache.put(Bier.name(), t()) :: :ok`
  - `Bier.SchemaCache.get(Bier.name()) :: t()` (empty struct when never loaded)
  - `Bier.SchemaCache.relations(Bier.name()) :: map()`
  - `Bier.SchemaCache.functions(Bier.name()) :: map()`
  - `Bier.SchemaCache.media_handlers(Bier.name()) :: list()`
  - `Bier.SchemaCache.schema_comment(Bier.name()) :: String.t() | nil`
  - `Bier.SchemaCache.loaded?(Bier.name()) :: boolean()`
  - Storage key: `{Bier, :schema_cache, name}` in `:persistent_term`.

- [ ] **Step 1: Write the failing test**

Create `test/bier/schema_cache_test.exs`:

```elixir
defmodule Bier.SchemaCacheTest do
  @moduledoc """
  Unit tests for the single-key schema-cache snapshot. Instance names are
  unique per test so the shared conformance instance's cache is never touched.
  """
  use ExUnit.Case, async: true

  alias Bier.SchemaCache

  defp unique_name, do: :"schema_cache_test_#{System.unique_integer([:positive])}"

  describe "get/1 and loaded?/1 on a never-loaded instance" do
    test "returns an empty snapshot and reports not loaded" do
      name = unique_name()

      assert %SchemaCache{
               relations: %{},
               functions: %{},
               media_handlers: [],
               schema_comment: nil
             } = SchemaCache.get(name)

      refute SchemaCache.loaded?(name)
    end
  end

  describe "put/2" do
    test "swaps the whole snapshot atomically under one persistent_term key" do
      name = unique_name()
      on_exit(fn -> :persistent_term.erase({Bier, :schema_cache, name}) end)

      cache = %SchemaCache{
        relations: %{{"public", "users"} => :fake_relation},
        functions: %{{"public", "fn"} => [:fake_overload]},
        media_handlers: [:fake_handler],
        schema_comment: "a comment"
      }

      assert :ok = SchemaCache.put(name, cache)

      assert SchemaCache.get(name) == cache
      assert SchemaCache.relations(name) == cache.relations
      assert SchemaCache.functions(name) == cache.functions
      assert SchemaCache.media_handlers(name) == cache.media_handlers
      assert SchemaCache.schema_comment(name) == "a comment"
      assert SchemaCache.loaded?(name)

      # The snapshot is ONE persistent_term entry — the atomic-swap guarantee.
      assert :persistent_term.get({Bier, :schema_cache, name}) == cache
    end

    test "loaded?/1 is false for a present but empty snapshot" do
      name = unique_name()
      on_exit(fn -> :persistent_term.erase({Bier, :schema_cache, name}) end)

      assert :ok = SchemaCache.put(name, %SchemaCache{})
      refute SchemaCache.loaded?(name)
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/bier/schema_cache_test.exs`
Expected: **compilation error** — `Bier.SchemaCache.__struct__/1 is undefined, cannot expand struct Bier.SchemaCache` (the module does not exist yet).

- [ ] **Step 3: Write the minimal implementation**

Create `lib/bier/schema_cache.ex`:

```elixir
defmodule Bier.SchemaCache do
  @moduledoc """
  The per-instance, in-memory snapshot of the database introspection results.

  One `%Bier.SchemaCache{}` per instance lives in `:persistent_term` under
  `{Bier, :schema_cache, name}`. Storing the four introspection results
  (relations, functions, media handlers, schema comment) as a single term
  makes a reload swap atomic: a request in flight during a reload sees either
  the old snapshot or the new one, never a mix.

  `:persistent_term.put/2` triggers a global GC pass when an existing key is
  replaced, so the snapshot must only be swapped at boot / reload frequency
  (DDL changes), never per request. Reads are effectively free.

  The entry is not erased when an instance stops — mirroring the previous
  per-key behavior; a restarted instance simply overwrites it.
  """

  defstruct relations: %{}, functions: %{}, media_handlers: [], schema_comment: nil

  @type t :: %__MODULE__{
          relations: map(),
          functions: map(),
          media_handlers: list(),
          schema_comment: String.t() | nil
        }

  @doc "Atomically swaps the snapshot for instance `name`."
  @spec put(Bier.name(), t()) :: :ok
  def put(name, %__MODULE__{} = cache), do: :persistent_term.put(key(name), cache)

  @doc "Returns the current snapshot for `name` (an empty one when never loaded)."
  @spec get(Bier.name()) :: t()
  def get(name), do: :persistent_term.get(key(name), %__MODULE__{})

  @doc "The relations map of the current snapshot, keyed by `{schema, name}`."
  @spec relations(Bier.name()) :: map()
  def relations(name), do: get(name).relations

  @doc "The callable functions map of the current snapshot, keyed by `{schema, name}`."
  @spec functions(Bier.name()) :: map()
  def functions(name), do: get(name).functions

  @doc "The custom media handlers of the current snapshot."
  @spec media_handlers(Bier.name()) :: list()
  def media_handlers(name), do: get(name).media_handlers

  @doc "The default schema's COMMENT, used by the OpenAPI document."
  @spec schema_comment(Bier.name()) :: String.t() | nil
  def schema_comment(name), do: get(name).schema_comment

  @doc "Whether a non-empty snapshot has been loaded for `name`."
  @spec loaded?(Bier.name()) :: boolean()
  def loaded?(name), do: map_size(relations(name)) > 0

  defp key(name), do: {Bier, :schema_cache, name}
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/bier/schema_cache_test.exs`
Expected: `3 tests, 0 failures`

- [ ] **Step 5: Commit**

```bash
mix format
git add lib/bier/schema_cache.ex test/bier/schema_cache_test.exs
git commit -m "feat(#29): add Bier.SchemaCache single-key snapshot"
```

---

### Task 2: `load!/3` and migration of boot + all read sites

**Files:**
- Modify: `lib/bier/schema_cache.ex` (add `load!/3`)
- Modify: `lib/bier/http_server_starter.ex` (boot path)
- Modify: `lib/bier/health.ex:22-24`
- Modify: `lib/bier/plan.ex:45-47`
- Modify: `lib/bier/custom_media.ex:182`
- Modify: `lib/bier/plugs/action_controller.ex:41`, `:170-197`, `:393`
- Modify: `lib/bier/rpc.ex:45`, `:271`
- Modify: `lib/bier/mutation.ex:196`
- Test: `test/bier/schema_cache_test.exs` (extend the file created in Task 1)

**Interfaces:**
- Consumes: Task 1's `put/2`, `get/1`, accessors.
- Produces: `Bier.SchemaCache.load!(Bier.name(), conn :: term(), [String.t(), ...]) :: t()` — `conn` is anything `Bier.Introspection` accepts (the pool via-tuple `Bier.Registry.via(name, Postgrex)` or a raw pid); raises on introspection failure; wraps the run in the existing `[:bier, :schema_cache, :load, *]` telemetry span with metadata `%{instance: name, schemas: schemas}`.

- [ ] **Step 1: Write the failing test**

Append inside `defmodule Bier.SchemaCacheTest` (after the `put/2` describe block) in `test/bier/schema_cache_test.exs`:

```elixir
  describe "load!/3" do
    @describetag :integration

    test "runs the DB introspection inside the telemetry span and returns a populated snapshot" do
      name = unique_name()
      base = Bier.ConformanceServer.base_opts()

      {:ok, pool} =
        [
          hostname: base[:hostname],
          port: base[:port],
          database: base[:database],
          username: base[:username],
          password: base[:password],
          pool_size: 1
        ]
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Postgrex.start_link()

      ref = :telemetry_test.attach_event_handlers(self(), [[:bier, :schema_cache, :load, :stop]])
      on_exit(fn -> :telemetry.detach(ref) end)

      cache = SchemaCache.load!(name, pool, ["test"])

      assert %SchemaCache{} = cache
      assert map_size(cache.relations) > 0
      # The fixture "test" schema carries a COMMENT (conformance case 1656).
      assert is_binary(cache.schema_comment)

      assert_receive {[:bier, :schema_cache, :load, :stop], ^ref, %{duration: _},
                      %{instance: ^name, schemas: ["test"], relation_count: count}}

      assert count == map_size(cache.relations)
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/bier/schema_cache_test.exs`
Expected: `4 tests, 1 failure` — `UndefinedFunctionError: function Bier.SchemaCache.load!/3 is undefined or private`.

- [ ] **Step 3: Add `load!/3` to `lib/bier/schema_cache.ex`**

Insert after the `@type t` definition and before `put/2`:

```elixir
  @doc """
  Runs the full DB introspection for `schemas` against `conn` and returns the
  resulting snapshot (without storing it — see `put/2`).

  Wrapped in the `[:bier, :schema_cache, :load, *]` telemetry span with
  metadata `%{instance: name, schemas: schemas}`; a failing introspection
  raises and surfaces as the span's `:exception` event.
  """
  @spec load!(Bier.name(), term(), [String.t(), ...]) :: t()
  def load!(name, conn, schemas) do
    Bier.Telemetry.schema_cache_load(%{instance: name, schemas: schemas}, fn ->
      cache = %__MODULE__{
        relations: Bier.Introspection.run(conn, schemas),
        functions: Bier.Introspection.functions(conn, schemas),
        media_handlers: Bier.Introspection.media_handlers(conn, schemas),
        schema_comment: Bier.Introspection.schema_comment(conn, hd(schemas))
      }

      {cache, %{relation_count: map_size(cache.relations)}}
    end)
  end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/bier/schema_cache_test.exs`
Expected: `4 tests, 0 failures`

- [ ] **Step 5: Migrate the boot path**

Replace the whole `init/1` body in `lib/bier/http_server_starter.ex` (keep the module, `start_link/1`, and `handle_continue/2` as they are; leave the trailing TODO comment for Task 6 to delete). The `init/1` currently spanning lines 11–43 becomes:

```elixir
  @impl GenServer
  def init(%Bier.Config{name: name, db_schemas: schemas} = conf) do
    conn = Bier.Registry.via(name, Postgrex)

    # The request pipeline resolves {schema, relation} on every request, so
    # the introspection snapshot lives in :persistent_term (read-mostly),
    # keyed by the instance name — see Bier.SchemaCache. The catch-all router
    # forwards everything to ActionController.
    cache = Bier.SchemaCache.load!(name, conn, schemas)
    Bier.SchemaCache.put(name, cache)

    {:module, plug, _binary, _} = Bier.RouterBuilder.build(conf, cache.relations)

    {:ok, %{conf: conf, plug: plug}, {:continue, :start_webserver}}
  end
```

(The old `%{conf: conf, relations: relations, plug: plug}` state carried
`relations` that nothing read — drop it.)

- [ ] **Step 6: Migrate the nine read sites**

`lib/bier/health.ex` — replace the private function (lines 22–24):

```elixir
  defp schema_cache_populated?(name) do
    Bier.SchemaCache.loaded?(name)
  end
```

`lib/bier/plan.ex` — replace the private function (lines 45–47):

```elixir
  defp relations(conn) do
    Bier.SchemaCache.relations(conn.assigns.supervisor_name)
  end
```

`lib/bier/custom_media.ex` — replace line 182:

```elixir
  defp handlers(name), do: Bier.SchemaCache.media_handlers(name)
```

`lib/bier/plugs/action_controller.ex` line 41 — replace:

```elixir
    relations = Bier.SchemaCache.relations(name)
```

`lib/bier/plugs/action_controller.ex` — in the comment block above
`build_openapi_document/2` (lines ~170–175), replace the sentence fragment
`come from the boot-time :persistent_term snapshot —` with
`come from the Bier.SchemaCache snapshot —`. Then replace the body reads
(lines ~179–197). Old:

```elixir
    relations =
      {Bier, :relations, config.name}
      |> :persistent_term.get(%{})
      |> Map.values()
      |> Enum.filter(&(&1.schema == schema))

    functions =
      {Bier, :functions, config.name}
      |> :persistent_term.get(%{})
      |> Map.filter(fn {{s, _name}, _overloads} -> s == schema end)
```

New (one `get/1` — the OpenAPI document now reads a single atomic snapshot):

```elixir
    cache = Bier.SchemaCache.get(config.name)

    relations =
      cache.relations
      |> Map.values()
      |> Enum.filter(&(&1.schema == schema))

    functions = Map.filter(cache.functions, fn {{s, _name}, _overloads} -> s == schema end)
```

and in the same function's `Bier.OpenAPI.build/1` call, replace

```elixir
      schema_comment: :persistent_term.get({Bier, :schema_comment, config.name}, nil),
```

with

```elixir
      schema_comment: cache.schema_comment,
```

`lib/bier/plugs/action_controller.ex` line 393 — replace:

```elixir
    relations = Bier.SchemaCache.relations(config.name)
```

`lib/bier/rpc.ex` line 45 — replace:

```elixir
      functions = Bier.SchemaCache.functions(config.name)
```

`lib/bier/rpc.ex` line 271 — replace:

```elixir
    relations = Bier.SchemaCache.relations(config.name)
```

`lib/bier/mutation.ex` line 196 — replace:

```elixir
    relations = Bier.SchemaCache.relations(write.config.name)
```

Verify no old-key access remains in `lib/`:

Run: `grep -rn ":persistent_term" lib/ | grep -v schema_cache.ex`
Expected: **no output** — after this task, `lib/bier/schema_cache.ex` is the only module touching `:persistent_term`. Any hit means a site was missed.

- [ ] **Step 7: Run the full suite as the regression net**

Run: `mix test`
Expected: **only the 3 pre-existing geojson/PostGIS failures** (cases 1616/1617/1618 — see Global Constraints), i.e. `685 tests, 3 failures`-shaped output with no new failure. `test/bier/health_test.exs` still passes — its old-key write is now inert and both its tests assert the negative.

- [ ] **Step 8: Commit**

```bash
mix format
git add lib/ test/bier/schema_cache_test.exs
git commit -m "refactor(#29): route schema-cache reads through Bier.SchemaCache"
```

---

### Task 3: `reload/1` + public `Bier.reload_schema_cache/1`

**Files:**
- Modify: `lib/bier/schema_cache.ex` (add `reload/1`)
- Modify: `lib/bier.ex` (add `reload_schema_cache/1` delegate, after `json_library/0`)
- Test: `test/bier/schema_cache_reload_test.exs` (new file)

**Interfaces:**
- Consumes: Task 1/2 (`load!/3`, `put/2`, `relations/1`), `Bier.Registry.whereis/1`, `Bier.Registry.config/1`, `Bier.Registry.via/2`.
- Produces:
  - `Bier.SchemaCache.reload(Bier.name()) :: :ok | {:error, :unknown_instance} | {:error, term()}`
  - `Bier.reload_schema_cache(Bier.name())` — same contract (defdelegate).

- [ ] **Step 1: Write the failing test**

Create `test/bier/schema_cache_reload_test.exs`:

```elixir
defmodule Bier.SchemaCacheReloadTest do
  @moduledoc """
  Boots a dedicated Bier instance against the test DB and exercises the
  programmatic schema-cache reload (`Bier.reload_schema_cache/1`) end to end.
  Not async: it binds a real port and runs DB introspection at boot.
  """
  use ExUnit.Case, async: false

  alias Bier.TestPorts

  @moduletag :integration

  defp start_instance do
    port = TestPorts.free_port()
    name = :"reload_it_#{System.unique_integer([:positive])}"

    opts =
      [name: name, router: [port: port, scheme: :http]] ++
        Bier.ConformanceServer.base_opts()

    start_supervised!({Bier, opts})
    TestPorts.wait_until_listening(port)
    %{name: name, port: port}
  end

  test "reload_schema_cache/1 picks up a table created after boot" do
    %{name: name} = start_instance()
    pool = Bier.Registry.via(name, Postgrex)
    table = "reload_probe_#{System.unique_integer([:positive])}"

    {:ok, _} = Postgrex.query(pool, "CREATE TABLE test.#{table} (id integer)", [])
    # The bier_test DB is dropped and recreated by every `mix test` run, so a
    # table leaked by a mid-test crash cannot outlive this run.

    refute Map.has_key?(Bier.SchemaCache.relations(name), {"test", table})

    assert :ok = Bier.reload_schema_cache(name)

    assert Map.has_key?(Bier.SchemaCache.relations(name), {"test", table})

    {:ok, _} = Postgrex.query(pool, "DROP TABLE test.#{table}", [])
  end

  test "returns an error for a name that is not a running instance (old cache untouched)" do
    name = :"never_started_#{System.unique_integer([:positive])}"

    assert {:error, :unknown_instance} = Bier.reload_schema_cache(name)
    refute Bier.SchemaCache.loaded?(name)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/bier/schema_cache_reload_test.exs`
Expected: `2 tests, 2 failures` — `UndefinedFunctionError: function Bier.reload_schema_cache/1 is undefined or private`.

- [ ] **Step 3: Write the minimal implementation**

In `lib/bier/schema_cache.ex`, add `alias Bier.Registry` directly under the
`@moduledoc` block, and insert after `loaded?/1`:

```elixir
  @doc """
  Re-runs the database introspection for the **running** instance `name` and
  atomically swaps its snapshot — the programmatic equivalent of PostgREST's
  `NOTIFY pgrst, 'reload schema'`.

  Resolves the instance's config and connection pool from `Bier.Registry`, so
  it works whether or not the LISTEN/NOTIFY listener (`db_channel_enabled`)
  is running. The swap happens only after a fully successful introspection:
  on any failure the previous snapshot stays in place and `{:error, reason}`
  is returned. An unregistered `name` returns `{:error, :unknown_instance}`.
  """
  @spec reload(Bier.name()) :: :ok | {:error, term()}
  def reload(name) do
    case Registry.whereis(name) do
      nil ->
        {:error, :unknown_instance}

      _pid ->
        config = Registry.config(name)
        put(name, load!(name, Registry.via(name, Postgrex), config.db_schemas))
        :ok
    end
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, reason}
  end
```

In `lib/bier.ex`, insert after the `json_library/0` function (before the
final `end`):

```elixir
  @doc """
  Re-runs the database introspection for the running instance `name` and
  atomically swaps its schema cache — the programmatic equivalent of
  PostgREST's `NOTIFY pgrst, 'reload schema'` (or SIGUSR1).

  Works whether or not the instance's LISTEN/NOTIFY listener is enabled
  (`db_channel_enabled`). Returns `{:error, :unknown_instance}` when no
  instance is registered under `name`; an introspection failure leaves the
  previous cache serving and is returned as `{:error, reason}`.
  """
  @spec reload_schema_cache(name()) :: :ok | {:error, term()}
  defdelegate reload_schema_cache(name), to: Bier.SchemaCache, as: :reload
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/bier/schema_cache_reload_test.exs`
Expected: `2 tests, 0 failures`

- [ ] **Step 5: Commit**

```bash
mix format
git add lib/bier/schema_cache.ex lib/bier.ex test/bier/schema_cache_reload_test.exs
git commit -m "feat(#29): add Bier.reload_schema_cache/1"
```

---

### Task 4: `db_channel` / `db_channel_enabled` config options

**Files:**
- Modify: `lib/bier.ex` (`schema/0` — insert the two options after the `db_pre_request:` entry)
- Modify: `lib/bier/config.ex` (`@type t`, `defstruct`, new validator wired into `new!/2`)
- Test: `test/bier/db_channel_config_test.exs` (new file)

**Interfaces:**
- Consumes: nothing new.
- Produces (Task 6 depends on these exact names):
  - `%Bier.Config{db_channel: String.t(), db_channel_enabled: boolean()}` (defaults `"pgrst"` / `true`)
  - `Bier.Config.validate_db_channel(String.t()) :: :ok | {:error, String.t()}`

- [ ] **Step 1: Write the failing test**

Create `test/bier/db_channel_config_test.exs`:

```elixir
defmodule Bier.DbChannelConfigTest do
  use ExUnit.Case, async: true

  describe "schema defaults" do
    test "db_channel defaults to \"pgrst\" and db_channel_enabled to true (PostgREST parity)" do
      conf = Bier.Config.new!([], Bier.schema())

      assert conf.db_channel == "pgrst"
      assert conf.db_channel_enabled == true
    end

    test "both options are configurable" do
      conf =
        Bier.Config.new!(
          [db_channel: "my_channel", db_channel_enabled: false],
          Bier.schema()
        )

      assert conf.db_channel == "my_channel"
      assert conf.db_channel_enabled == false
    end
  end

  describe "validate_db_channel/1" do
    test "a regular channel name is ok" do
      assert Bier.Config.validate_db_channel("pgrst") == :ok
    end

    test "empty is rejected" do
      assert Bier.Config.validate_db_channel("") ==
               {:error, "db-channel cannot be empty"}
    end

    test "longer than 63 bytes is rejected (Postgres identifier limit)" do
      assert Bier.Config.validate_db_channel(String.duplicate("a", 64)) ==
               {:error, "db-channel cannot exceed 63 bytes"}
    end

    test "new!/2 enforces it" do
      assert_raise ArgumentError, ~r/db-channel cannot be empty/, fn ->
        Bier.Config.new!([db_channel: ""], Bier.schema())
      end
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/bier/db_channel_config_test.exs`
Expected: `6 tests, 6 failures` — `KeyError` for `:db_channel` on the default
test, `NimbleOptions.ValidationError` (`unknown options [:db_channel, …]`) on
the configured one, `UndefinedFunctionError` for `validate_db_channel/1`.

- [ ] **Step 3: Write the minimal implementation**

`lib/bier.ex` — in `schema/0`, insert after the `db_pre_request:` entry
(currently ending at line 214) and before `jwt_secret:`:

```elixir
      db_channel: [
        type: :string,
        default: env(:db_channel, "pgrst"),
        doc: """
        Postgres notification channel the schema-cache listener subscribes to
        (PostgREST db-channel). `NOTIFY <channel>, 'reload schema'` re-runs
        the DB introspection and atomically swaps the instance's schema
        cache; see `db_channel_enabled`.
        """
      ],
      db_channel_enabled: [
        type: :boolean,
        default: env(:db_channel_enabled, true),
        doc: """
        Whether the instance opens a dedicated LISTEN connection on
        `db_channel` and reloads its schema cache on NOTIFY (PostgREST
        db-channel-enabled). Enabled by default, matching PostgREST;
        disabling it saves one database connection per instance.
        `Bier.reload_schema_cache/1` works either way.
        """
      ],
```

`lib/bier/config.ex` — three edits:

1. In `@type t`, after the `db_pre_request: String.t() | nil,` line add:

```elixir
          db_channel: String.t(),
          db_channel_enabled: boolean(),
```

2. In `defstruct`, add to the defaulted section (after `db_safe_update_tables: [],`):

```elixir
    db_channel: "pgrst",
    db_channel_enabled: true,
```

3. In `new!/2`, after the `raise_if_error!(validate_jwt_aud(conf[:jwt_aud]))` line add:

```elixir
    raise_if_error!(validate_db_channel(conf[:db_channel]))
```

and add the validator next to the other `validate_*` functions:

```elixir
  @doc """
  `db-channel` must be a non-empty channel name of at most 63 bytes (the
  Postgres identifier limit). `Postgrex.Notifications.listen/3` enforces the
  same bound at runtime by raising — validating at boot turns a would-be
  listener crash-loop into a fast `ArgumentError`. Library-enforced (PostgREST
  does not validate this key), like the admin-port collision rule.
  """
  @spec validate_db_channel(String.t() | nil) :: :ok | {:error, String.t()}
  def validate_db_channel(nil), do: :ok

  def validate_db_channel(channel) when is_binary(channel) do
    cond do
      channel == "" -> {:error, "db-channel cannot be empty"}
      byte_size(channel) > 63 -> {:error, "db-channel cannot exceed 63 bytes"}
      true -> :ok
    end
  end
```

(`nil` is accepted because `new!/2` may be called with schemas that omit the
key; the NimbleOptions default always supplies it from `Bier.schema/0`.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/bier/db_channel_config_test.exs test/bier/config_test.exs`
Expected: `0 failures` (the new file and the untouched existing config tests).

- [ ] **Step 5: Commit**

```bash
mix format
git add lib/bier.ex lib/bier/config.ex test/bier/db_channel_config_test.exs
git commit -m "feat(#29): add db_channel / db_channel_enabled options"
```

---

### Task 5: CLI parity — `db-channel` / `db-channel-enabled`

**Files:**
- Modify: `lib/bier/cli/config.ex` (`@entries` + `to_start_opts/1`)
- Test: `test/bier/cli/db_channel_test.exs` (new file)

**Interfaces:**
- Consumes: Task 4's option names `:db_channel` / `:db_channel_enabled`.
- Produces: resolved-config keys `"db-channel"` / `"db-channel-enabled"`, env vars `PGRST_DB_CHANNEL` / `PGRST_DB_CHANNEL_ENABLED`.

- [ ] **Step 1: Write the failing test**

Create `test/bier/cli/db_channel_test.exs`:

```elixir
defmodule Bier.CLI.DbChannelTest do
  use ExUnit.Case, async: true

  alias Bier.CLI.Config

  test "defaults: db-channel = \"pgrst\", db-channel-enabled = true" do
    {:ok, resolved} = Config.load(%{}, nil, %{})

    assert resolved["db-channel"] == "pgrst"
    assert resolved["db-channel-enabled"] == true
  end

  test "PGRST_DB_CHANNEL / PGRST_DB_CHANNEL_ENABLED are honored and mapped to start opts" do
    {:ok, resolved} =
      Config.load(
        %{"PGRST_DB_CHANNEL" => "my_channel", "PGRST_DB_CHANNEL_ENABLED" => "false"},
        nil,
        %{}
      )

    opts = Config.to_start_opts(resolved)

    assert opts[:db_channel] == "my_channel"
    assert opts[:db_channel_enabled] == false
    assert %Bier.Config{} = Bier.Config.new!(opts, Bier.schema())
  end

  test "--dump-config renders both keys" do
    {:ok, resolved} = Config.load(%{}, nil, %{})
    dump = resolved |> Config.dump() |> IO.iodata_to_binary()

    assert dump =~ ~s(db-channel = "pgrst")
    assert dump =~ "db-channel-enabled = true"
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/bier/cli/db_channel_test.exs`
Expected: `3 tests, 3 failures` — `resolved["db-channel"]` is `nil` (key not
in the spec table), `opts[:db_channel]` is `nil`, and `Config.dump/1` raises
nothing but contains neither key (`refute`-style mismatch on `=~`).

- [ ] **Step 3: Write the minimal implementation**

`lib/bier/cli/config.ex` — in `@entries`, insert after the `db-anon-role`
entry (position is cosmetic — `dump/1` sorts keys alphabetically):

```elixir
    %{
      key: "db-channel",
      env: "PGRST_DB_CHANNEL",
      kind: :string,
      default: "pgrst",
      aliases: []
    },
    %{
      key: "db-channel-enabled",
      env: "PGRST_DB_CHANNEL_ENABLED",
      kind: :bool,
      default: true,
      aliases: []
    },
```

In `to_start_opts/1`, add to the `direct` keyword list (after
`db_plan_enabled: resolved["db-plan-enabled"],`):

```elixir
        db_channel: resolved["db-channel"],
        db_channel_enabled: resolved["db-channel-enabled"],
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/bier/cli test/bier/cli_test.exs && mix test --only area:cli`
Expected: `0 failures` in both runs (the new file, the existing CLI unit
tests — their dump assertions are substring-based — and the active `cli`
conformance area; the full-table dump case 1705 is deferred and unaffected).

- [ ] **Step 5: Commit**

```bash
mix format
git add lib/bier/cli/config.ex test/bier/cli/db_channel_test.exs
git commit -m "feat(#29): CLI support for db-channel / db-channel-enabled"
```

---

### Task 6: `Bier.SchemaCacheListener` — LISTEN/NOTIFY reload

**Files:**
- Create: `lib/bier/schema_cache_listener.ex`
- Modify: `lib/bier.ex` (`init/1` children list + new private `listener_children/1`)
- Modify: `lib/bier/http_server_starter.ex` (delete the stale trailing TODO comment, lines 66–70 of the original file — this feature implements it)
- Test: `test/bier/schema_cache_listener_test.exs` (new file)

**Interfaces:**
- Consumes: Task 2–4 (`Bier.SchemaCache.reload/1`, `%Bier.Config{db_channel: …, db_channel_enabled: …}`), `Bier.postgrex_opts/1`, `Bier.Registry.via/2`.
- Produces: `Bier.SchemaCacheListener.start_link(Bier.Config.t())`, registered under `Bier.Registry.via(name, Bier.SchemaCacheListener)`; discoverable via `Bier.Registry.whereis(name, Bier.SchemaCacheListener)`.

- [ ] **Step 1: Write the failing test**

Create `test/bier/schema_cache_listener_test.exs`:

```elixir
defmodule Bier.SchemaCacheListenerTest do
  @moduledoc """
  Boots dedicated Bier instances against the test DB and exercises the
  LISTEN/NOTIFY schema-cache reload end to end. Every instance gets its own
  unique notification channel so these tests never signal the shared
  conformance instance (which listens on the default "pgrst").

  Not async: binds real ports and runs DB introspection at boot.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Bier.TestPorts

  @moduletag :integration

  @load_stop [:bier, :schema_cache, :load, :stop]

  defp start_instance(extra_opts) do
    port = TestPorts.free_port()
    name = :"listener_it_#{System.unique_integer([:positive])}"

    opts =
      [name: name, router: [port: port, scheme: :http]] ++
        extra_opts ++ Bier.ConformanceServer.base_opts()

    start_supervised!({Bier, opts})
    TestPorts.wait_until_listening(port)
    %{name: name, port: port}
  end

  defp unique_channel, do: "bier_reload_test_#{System.unique_integer([:positive])}"

  defp notify(name, channel, payload) do
    {:ok, _} =
      Postgrex.query(
        Bier.Registry.via(name, Postgrex),
        "SELECT pg_notify($1, $2)",
        [channel, payload]
      )
  end

  defp attach_load_stop do
    ref = :telemetry_test.attach_event_handlers(self(), [@load_stop])
    on_exit(fn -> :telemetry.detach(ref) end)
    ref
  end

  # The listener subscribes in a handle_continue after its init returns, so a
  # NOTIFY fired immediately after boot can race the LISTEN and be lost
  # forever (notifications are not queued server-side). Poll the listener's
  # state until the subscription is up; only then is a NOTIFY guaranteed to
  # be delivered. (`:sys.get_state/1` blocks while the continue runs, so one
  # probe usually suffices.)
  defp await_listener_connected(name) do
    pid = Bier.Registry.whereis(name, Bier.SchemaCacheListener)
    assert is_pid(pid), "no schema-cache listener registered for #{inspect(name)}"
    await_subscription(pid, 200)
  end

  defp await_subscription(pid, attempts) do
    cond do
      :sys.get_state(pid).notifications != nil ->
        :ok

      attempts > 0 ->
        Process.sleep(25)
        await_subscription(pid, attempts - 1)

      true ->
        flunk("listener never established its LISTEN subscription")
    end
  end

  test "NOTIFY 'reload schema' makes a table created after boot servable" do
    channel = unique_channel()
    %{name: name, port: port} = start_instance(db_channel: channel)

    await_listener_connected(name)

    pool = Bier.Registry.via(name, Postgrex)
    table = "notify_probe_#{System.unique_integer([:positive])}"
    {:ok, _} = Postgrex.query(pool, "CREATE TABLE test.#{table} (id integer)", [])

    {:ok, _} =
      Postgrex.query(
        pool,
        "GRANT SELECT ON test.#{table} TO postgrest_test_anonymous",
        []
      )

    # Stale cache: the API does not know the table yet.
    assert Req.get!("http://127.0.0.1:#{port}/#{table}", retry: false).status == 404

    ref = attach_load_stop()
    notify(name, channel, "reload schema")
    assert_receive {@load_stop, ^ref, %{duration: _}, %{instance: ^name}}, 5_000

    assert Req.get!("http://127.0.0.1:#{port}/#{table}", retry: false).status == 200

    {:ok, _} = Postgrex.query(pool, "DROP TABLE test.#{table}", [])
  end

  test "an empty payload also reloads (PostgREST: empty = schema + config)" do
    channel = unique_channel()
    %{name: name} = start_instance(db_channel: channel)
    await_listener_connected(name)

    ref = attach_load_stop()
    notify(name, channel, "")
    assert_receive {@load_stop, ^ref, %{duration: _}, %{instance: ^name}}, 5_000
  end

  test "'reload config' is a logged no-op and does not reload" do
    channel = unique_channel()
    %{name: name} = start_instance(db_channel: channel)
    await_listener_connected(name)

    ref = attach_load_stop()

    log =
      capture_log(fn ->
        notify(name, channel, "reload config")
        refute_receive {@load_stop, ^ref, _, %{instance: ^name}}, 1_000
      end)

    assert log =~ "reload config"
  end

  test "an unknown payload is ignored" do
    channel = unique_channel()
    %{name: name} = start_instance(db_channel: channel)
    await_listener_connected(name)

    ref = attach_load_stop()
    notify(name, channel, "reload everything!!")
    refute_receive {@load_stop, ^ref, _, %{instance: ^name}}, 1_000
  end

  test "db_channel_enabled: false starts no listener" do
    %{name: name} = start_instance(db_channel_enabled: false)

    assert Bier.Registry.whereis(name, Bier.SchemaCacheListener) == nil
  end

  test "a NOTIFY burst is coalesced into few reloads" do
    channel = unique_channel()
    %{name: name} = start_instance(db_channel: channel)
    await_listener_connected(name)

    ref = attach_load_stop()

    # Ten separate queries = ten separate transactions = ten real
    # notifications. (A single `SELECT pg_notify(...) FROM generate_series`
    # would NOT work: Postgres dedupes identical channel+payload
    # notifications within one transaction down to a single delivery.)
    for _ <- 1..10, do: notify(name, channel, "reload schema")

    assert_receive {@load_stop, ^ref, _, %{instance: ^name}}, 5_000

    # Soft upper bound: delivery timing can split the burst, but 10 separate
    # reloads would mean coalescing is broken.
    extra =
      Enum.count(1..9, fn _ ->
        receive do
          {@load_stop, ^ref, _, %{instance: ^name}} -> true
        after
          300 -> false
        end
      end)

    assert extra <= 4
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/bier/schema_cache_listener_test.exs`
Expected: `6 tests, 5 failures` — every test that calls
`await_listener_connected/1` fails fast on its `is_pid` assertion (no
listener exists yet, so `Bier.Registry.whereis/2` returns `nil`). Only the
`db_channel_enabled: false` test passes vacuously at this stage (no listener
is the not-yet-implemented default); it gains its meaning once the listener
exists.

- [ ] **Step 3: Write the listener**

Create `lib/bier/schema_cache_listener.ex`:

```elixir
defmodule Bier.SchemaCacheListener do
  @moduledoc """
  Subscribes to the instance's `db_channel` Postgres notification channel and
  reloads the schema cache on PostgREST's reload signals
  (`NOTIFY <db_channel>, 'reload schema'`).

  ## Payloads

  Mirroring PostgREST's listener:

    * `"reload schema"` — re-run the DB introspection and atomically swap the
      instance's `Bier.SchemaCache` snapshot;
    * `""` (empty) — PostgREST reloads schema cache *and* config; Bier's
      config is host-supplied, so only the schema cache is reloaded;
    * `"reload config"` — logged no-op (host applications own Bier's config);
    * anything else — ignored with a debug log.

  Bursts are coalesced: reload signals already queued in the mailbox are
  drained before a single reload runs, so a migration firing one NOTIFY per
  DDL statement causes one introspection, not N.

  ## Connection ownership

  The listener owns a dedicated `Postgrex.Notifications` connection (LISTEN
  cannot go through the request pool), started with `auto_reconnect: false`,
  and traps exits: when the connection drops — or cannot be established — the
  listener stays alive and retries with exponential backoff. A database
  outage therefore never crash-loops the instance's supervisor; reload
  signals just pause while the last good snapshot keeps serving.

  Notifications sent while disconnected are lost, so after every
  *re*-connect the listener reloads unconditionally to catch up (PostgREST
  does the same). The very first connect skips that reload — the boot
  introspection has just run.

  A failed reload keeps the previous snapshot: `Bier.SchemaCache.reload/1`
  only swaps after a fully successful introspection.
  """

  use GenServer

  require Logger

  @initial_backoff 500
  @max_backoff 30_000

  def start_link(%Bier.Config{name: name} = conf) do
    GenServer.start_link(__MODULE__, conf, name: Bier.Registry.via(name, __MODULE__))
  end

  @impl GenServer
  def init(%Bier.Config{} = conf) do
    Process.flag(:trap_exit, true)

    state = %{
      conf: conf,
      notifications: nil,
      backoff: @initial_backoff,
      connected_before?: false
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, state), do: connect(state)

  @impl GenServer
  def handle_info(:connect, state), do: connect(state)

  def handle_info({:notification, _pid, _ref, _channel, payload}, state) do
    {:noreply, handle_payload(payload, state)}
  end

  def handle_info({:EXIT, pid, reason}, %{notifications: pid} = state) do
    Logger.warning(
      "Bier schema-cache listener for #{inspect(state.conf.name)} lost its " <>
        "LISTEN connection: #{inspect(reason)}"
    )

    {:noreply, schedule_reconnect(%{state | notifications: nil})}
  end

  # An EXIT from a process we no longer track (e.g. a connection already
  # replaced after an earlier failure) — nothing to do.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  # The LISTEN connection cannot go through the request pool, so the listener
  # runs its own single Postgrex.Notifications connection built from the same
  # instance options.
  defp connect(%{conf: conf} = state) do
    opts =
      conf
      |> Bier.postgrex_opts()
      |> Keyword.drop([:name, :pool_size])
      |> Keyword.merge(sync_connect: true, auto_reconnect: false)

    case Postgrex.Notifications.start_link(opts) do
      {:ok, pid} ->
        {:ok, _ref} = Postgrex.Notifications.listen(pid, conf.db_channel)

        # Notifications sent while we were down are lost — after a REconnect,
        # reload unconditionally to catch up. On the very first connect the
        # boot introspection just ran, so skip it.
        if state.connected_before?, do: reload(conf.name)

        {:noreply,
         %{state | notifications: pid, backoff: @initial_backoff, connected_before?: true}}

      {:error, reason} ->
        Logger.warning(
          "Bier schema-cache listener for #{inspect(conf.name)} cannot reach " <>
            "the database (retrying in #{state.backoff}ms): #{inspect(reason)}"
        )

        {:noreply, schedule_reconnect(state)}
    end
  end

  defp schedule_reconnect(state) do
    Process.send_after(self(), :connect, state.backoff)
    %{state | backoff: min(state.backoff * 2, @max_backoff)}
  end

  # PostgREST semantics: "reload schema" reloads the schema cache; an empty
  # payload means "reload schema cache AND config" — the config half is a
  # no-op here, so both trigger the same schema reload.
  defp handle_payload(payload, state) when payload in ["reload schema", ""] do
    drain_reload_signals()
    reload(state.conf.name)
    state
  end

  defp handle_payload("reload config", state) do
    Logger.info(
      "Bier received 'reload config' on #{inspect(state.conf.db_channel)}: " <>
        "ignored — Bier's config is supplied by the host application"
    )

    state
  end

  defp handle_payload(other, state) do
    Logger.debug(
      "Bier ignoring unknown payload on #{inspect(state.conf.db_channel)}: #{inspect(other)}"
    )

    state
  end

  # Coalesce bursts: consume every reload signal already queued so N
  # back-to-back NOTIFYs cause one introspection run, not N.
  defp drain_reload_signals do
    receive do
      {:notification, _pid, _ref, _channel, payload}
      when payload in ["reload schema", ""] ->
        drain_reload_signals()
    after
      0 -> :ok
    end
  end

  defp reload(name) do
    case Bier.SchemaCache.reload(name) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Bier schema-cache reload for #{inspect(name)} failed; keeping the " <>
            "previous snapshot: #{inspect(reason)}"
        )
    end
  end
end
```

- [ ] **Step 4: Wire it into the `Bier` supervisor**

In `lib/bier.ex`, `init/1` currently ends the children list with:

```elixir
        {Bier.HttpServerStarter, conf}
      ] ++ admin_children(conf)
```

Change it to:

```elixir
        {Bier.HttpServerStarter, conf}
      ] ++ listener_children(conf) ++ admin_children(conf)
```

and add above `admin_children/1`:

```elixir
  # When `db_channel_enabled` (the default, matching PostgREST), run the
  # LISTEN/NOTIFY schema-cache listener. Started after HttpServerStarter so
  # the boot introspection has already populated the cache by the time the
  # listener first connects — its catch-up reload only applies to REconnects.
  # The listener owns its DB connection and retries with internal backoff, so
  # a database outage never builds restart pressure on this supervisor.
  defp listener_children(%Bier.Config{db_channel_enabled: false}), do: []

  defp listener_children(%Bier.Config{} = conf), do: [{Bier.SchemaCacheListener, conf}]
```

- [ ] **Step 5: Delete the stale TODO in `lib/bier/http_server_starter.ex`**

Remove the trailing comment block (the feature it asks about now exists):

```elixir
  # TODO: Check if it's possible to subscribe to all the changes in the
  # database, and capture those events via `Postgrex.Notifications`, that way
  # you can insert here a `handle_info/2` to update the db structure and also
  # re-build? the Router?
```

- [ ] **Step 6: Run the listener tests, then the full suite**

Run: `mix test test/bier/schema_cache_listener_test.exs`
Expected: `6 tests, 0 failures`

Run: `mix test`
Expected: **only the 3 pre-existing geojson/PostGIS failures** (see Global
Constraints) — no new failure. Note: the shared conformance instance and its
~18 variants each now open one extra LISTEN connection (~19 total on top of
~46 pooled) — still well inside Postgres' default `max_connections = 100`. If
the suite ever hits connection exhaustion, that budget is the first suspect.

- [ ] **Step 7: Commit**

```bash
mix format
git add lib/bier/schema_cache_listener.ex lib/bier.ex lib/bier/http_server_starter.ex test/bier/schema_cache_listener_test.exs
git commit -m "feat(#29): reload the schema cache via LISTEN/NOTIFY (db-channel)"
```

---

### Task 7: Documentation + full gates

**Files:**
- Modify: `README.md` (new subsection after "### Pluggable JSON"; boot-flow narrative; feature-gap list at line 284)
- Modify: `CLAUDE.md` (boot-sequence description; known-gaps sentence)

**Interfaces:**
- Consumes: everything shipped in Tasks 1–6 (names must match exactly: `db_channel`, `db_channel_enabled`, `Bier.reload_schema_cache/1`, `Bier.SchemaCache`, `Bier.SchemaCacheListener`).
- Produces: user-facing docs; no code.

- [ ] **Step 1: README — add the reload subsection**

Insert after the "### Pluggable JSON" subsection (which ends around line 111,
before "## Running standalone"):

````markdown
### Schema-cache reload

Bier introspects the database at boot and serves from that snapshot. After a
DDL change (new table, column, FK), reload the cache without restarting —
exactly like PostgREST:

```sql
NOTIFY pgrst, 'reload schema';
```

Every instance listens on the `db_channel` channel (default `"pgrst"`) with a
dedicated connection; set `db_channel_enabled: false` to opt out and save the
connection. From Elixir, `Bier.reload_schema_cache(MyApp.Bier)` does the same
on demand (PostgREST's SIGUSR1 equivalent). A failed reload keeps the
previous snapshot serving. `'reload config'` is accepted and logged, but a
no-op: the host application owns Bier's configuration.

To reload automatically on every DDL change, install PostgREST's event
trigger:

```sql
CREATE OR REPLACE FUNCTION public.pgrst_watch() RETURNS event_trigger
  LANGUAGE plpgsql
  AS $$
BEGIN
  NOTIFY pgrst, 'reload schema';
END;
$$;

CREATE EVENT TRIGGER pgrst_watch
  ON ddl_command_end
  EXECUTE PROCEDURE public.pgrst_watch();
```
````

- [ ] **Step 2: README — boot flow narrative + gap list**

In the paragraph right below the boot-flow mermaid diagram (after "… edit the
quoted block in `RouterBuilder` instead."), append this sentence:

```markdown
After `HttpServerStarter`, the supervisor also starts `Bier.SchemaCacheListener`
(unless `db_channel_enabled: false`), which LISTENs on `db_channel` and swaps
the `Bier.SchemaCache` snapshot on `NOTIFY … 'reload schema'`.
```

At line 284, remove `schema-cache reload` from the feature-gap list. Old:

```markdown
(observability/telemetry, schema-cache reload, admin/health endpoints, …).
```

New:

```markdown
(observability/telemetry, admin/health endpoints, …).
```

- [ ] **Step 3: CLAUDE.md — keep the project map truthful**

In the "Boot sequence (current state)" section, replace:

```markdown
`HttpServerStarter.init/1` runs real introspection — `Bier.Introspection.run/functions/media_handlers(pool, db_schemas)` — and stashes the results in **`:persistent_term`** keyed by `{Bier, :relations | :functions | :media_handlers, name}` (read on every request).
```

with:

```markdown
`HttpServerStarter.init/1` runs real introspection via `Bier.SchemaCache.load!/3` and stashes the snapshot (one `%Bier.SchemaCache{}` struct) in **`:persistent_term`** keyed by `{Bier, :schema_cache, name}` (read on every request through the `Bier.SchemaCache` accessors). A `Bier.SchemaCacheListener` child (gated by `db_channel_enabled`, default true) LISTENs on `db_channel` and atomically re-swaps the snapshot on `NOTIFY … 'reload schema'`; `Bier.reload_schema_cache/1` does the same programmatically.
```

In the "Project status" paragraph, remove `schema-cache reload` from the
known-gaps parenthetical (same mechanical edit as the README's line 284).

- [ ] **Step 4: Run every gate**

Do **not** use the `mix precommit` alias — its `test` step exits non-zero at
the pre-existing 3-failure baseline (see Global Constraints), so the alias
can never pass. Run the gates individually:

```bash
mix deps.unlock --check-unused && \
  mix format --check-formatted && \
  mix hex.audit && \
  mix compile --warnings-as-errors && \
  mix credo --strict && \
  mix docs --warnings-as-errors && \
  mix test
```

Expected: every gate up to `mix test` passes; `mix test` reports **exactly the
3 pre-existing geojson/PostGIS failures** (cases 1616/1617/1618) and nothing
else — that matches CI, which gates on the failure baseline, not on zero.
(`mix hex.audit` needs network access to hex.pm; if it fails offline, note the
skip in the PR — CI runs the full set.)

- [ ] **Step 5: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs(#29): document schema-cache reload"
```

---

## Verification sweep (after all tasks)

- [ ] `grep -rn "{Bier, :relations\|{Bier, :functions\|{Bier, :media_handlers\|{Bier, :schema_comment" lib/` → no output (only the frozen `test/bier/health_test.exs` may still mention the old key — it passes untouched).
- [ ] `mix test` → exactly the 3 pre-existing geojson/PostGIS failures (cases 1616/1617/1618), no new failure.
- [ ] Manual smoke (optional, needs a scratch DB): `iex -S mix`, start an instance, `CREATE TABLE`, `psql -c "NOTIFY pgrst, 'reload schema'"`, `curl` the new table.
- [ ] Spec coverage: every Goal in `docs/superpowers/specs/2026-07-03-schema-cache-reload-design.md` maps to a task — Goal 1 → Tasks 1/2/6, Goal 2 → Tasks 4/5, Goal 3 → Task 3, Goal 4 → Task 3 (structural: swap-after-load) + listener error branch, Goal 5 → Task 6 (backoff, never crashes on DB failure).
