# SSE Realtime Events Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A config-gated `GET /events` SSE endpoint that bridges PostgreSQL `LISTEN`/`NOTIFY` to streaming HTTP clients (issue #81, spec: `docs/superpowers/specs/2026-07-16-sse-realtime-events-design.md`).

**Architecture:** One per-instance `Bier.Events.Listener` GenServer (cloned from `Bier.SchemaCacheListener`'s connection-ownership pattern) LISTENs on all allowlisted channels and fans notifications out through a node-shared duplicate-keys `Bier.Events.Registry` to subscriber processes — the Bandit connection processes holding chunked SSE responses. Routing hooks into `Bier.Plugs.ActionController.dispatch/3`; errors flow through `Bier.Plugs.FallbackController` with new `BIER*` codes.

**Tech Stack:** Elixir ~> 1.18 (repo pins 1.20/OTP 29 via mise), Plug + Bandit (chunked responses), Postgrex.Notifications, `Registry` (stdlib), `:telemetry`. **No new dependencies.**

## Global Constraints

- NEVER edit `spec/**`, `test/conformance/**`, or `test/support/**` (frozen conformance ground truth). Do not modify existing test files either — this feature only ADDS new test files under `test/bier/`.
- The full conformance suite must stay green: `mix test` (requires a local Postgres; the alias reloads the `bier_test` fixture DB first).
- JSON serialization goes through `Bier.json_library()`, never `Jason`/`JSON` directly.
- New error shapes are `Bier.Plugs.FallbackController.call/2` clauses, never inline responses in controllers. Bier-specific (non-PostgREST) errors use the `BIER` code namespace: `BIER001` = unknown channel (404), `BIER002` = missing channel param (400).
- Run `mix format` before every commit. CI also runs `credo --strict` and `mix docs --warnings-as-errors` — keep moduledocs on every new module.
- Commit messages follow the repo convention `feat(#81): <summary>` / `docs(#81): <summary>`, and end with the Claude Code trailer used in this repo.
- Feature must be purely additive: with `events_channels: []` (the default) every request flows exactly as today.
- The branch is `feat/81-sse-realtime-events` (already created off origin/main).

---

### Task 1: Config surface (`events_channels`, `events_path`, `events_heartbeat_interval`)

**Files:**
- Modify: `lib/bier.ex` (schema/0, after the `admin_server_port` entry, ~line 409)
- Modify: `lib/bier/config.ex` (typespec, defstruct, `new/2` validation chain)
- Test: `test/bier/events_config_test.exs` (new file)

**Interfaces:**
- Consumes: existing `Bier.Config.new!/2`, `Bier.schema/0`.
- Produces: `%Bier.Config{events_channels: [String.t()], events_path: String.t(), events_heartbeat_interval: pos_integer()}` with defaults `[]` / `"events"` / `15_000`. Public validators `Bier.Config.validate_events_channels/1` and `Bier.Config.validate_events_path/1`, both `:ok | {:error, String.t()}`. Every later task reads these three struct fields.

- [ ] **Step 1: Write the failing test**

Create `test/bier/events_config_test.exs`:

```elixir
defmodule Bier.EventsConfigTest do
  use ExUnit.Case, async: true

  defp new!(overrides) do
    Bier.Config.new!(overrides, Bier.schema())
  end

  test "defaults: feature disabled, path 'events', heartbeat 15s" do
    conf = new!([])
    assert conf.events_channels == []
    assert conf.events_path == "events"
    assert conf.events_heartbeat_interval == 15_000
  end

  test "accepts a channel allowlist and custom path/heartbeat" do
    conf =
      new!(
        events_channels: ["chat", "jobs"],
        events_path: "realtime",
        events_heartbeat_interval: 50
      )

    assert conf.events_channels == ["chat", "jobs"]
    assert conf.events_path == "realtime"
    assert conf.events_heartbeat_interval == 50
  end

  test "rejects empty channel names" do
    assert_raise ArgumentError, ~r/events-channels entries cannot be empty/, fn ->
      new!(events_channels: [""])
    end
  end

  test "rejects channel names over 63 bytes" do
    assert_raise ArgumentError, ~r/cannot exceed 63 bytes/, fn ->
      new!(events_channels: [String.duplicate("a", 64)])
    end
  end

  test "rejects channel names containing double quotes or null bytes" do
    assert_raise ArgumentError, ~r/cannot contain double quotes/, fn ->
      new!(events_channels: [~s(bad"name)])
    end

    assert_raise ArgumentError, ~r/cannot contain null bytes/, fn ->
      new!(events_channels: [<<?a, 0, ?b>>])
    end
  end

  test "rejects an empty or multi-segment events_path" do
    assert_raise ArgumentError, ~r/events-path cannot be empty/, fn ->
      new!(events_channels: ["chat"], events_path: "")
    end

    assert_raise ArgumentError, ~r/single path segment/, fn ->
      new!(events_channels: ["chat"], events_path: "a/b")
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/bier/events_config_test.exs`
Expected: FAIL — `unknown options [:events_channels]` (NimbleOptions rejects the keys).

- [ ] **Step 3: Add the schema keys**

In `lib/bier.ex`, inside `schema/0`, after the `admin_server_port:` entry add:

```elixir
      events_channels: [
        type: {:list, :string},
        default: env(:events_channels, []),
        doc: """
        Allowlist of Postgres notification channels exposed on the SSE events
        endpoint. The empty list (default) disables the feature entirely: no
        listener connection is opened and no path is reserved. Bier-specific
        (no PostgREST counterpart); see the Realtime events guide.
        """
      ],
      events_path: [
        type: :string,
        default: env(:events_path, "events"),
        doc: """
        Top-level path segment reserved for the SSE events endpoint while
        `events_channels` is non-empty. Change it if a relation of the same
        name must stay reachable. Must be a single segment (no `/`).
        """
      ],
      events_heartbeat_interval: [
        type: :pos_integer,
        default: env(:events_heartbeat_interval, 15_000),
        doc: """
        Milliseconds of silence on an SSE connection before a `: keepalive`
        comment frame is written. Keeps idle proxies from dropping the
        stream and bounds dead-client detection.
        """
      ]
```

- [ ] **Step 4: Add struct fields, typespec, and validators in `lib/bier/config.ex`**

In the `@type t` map add:

```elixir
          events_channels: [String.t()],
          events_path: String.t(),
          events_heartbeat_interval: pos_integer(),
```

In `defstruct` (the keyword section with defaults) add:

```elixir
    events_channels: [],
    events_path: "events",
    events_heartbeat_interval: 15_000,
```

In `new/2`, extend the `with` chain (after `:ok <- validate_db_channel(conf[:db_channel])`):

```elixir
         :ok <- validate_events_channels(Keyword.get(conf, :events_channels, [])),
         :ok <- validate_events_path(Keyword.get(conf, :events_path, "events")),
```

Add the validators (near `validate_db_channel/1`):

```elixir
  @doc """
  Each `events-channels` entry must be a usable Postgres notification channel
  name: non-empty, at most 63 bytes (the identifier limit), no null bytes, and
  no double quotes (`Postgrex.Notifications.listen/3` wraps the name in double
  quotes without escaping). Validated at boot so a bad entry is a fast
  `ArgumentError` instead of a listener crash-loop. Bier-specific key.
  """
  @spec validate_events_channels([String.t()]) :: :ok | {:error, String.t()}
  def validate_events_channels(channels) when is_list(channels) do
    Enum.find_value(channels, :ok, fn channel ->
      case validate_channel_name(channel) do
        :ok -> nil
        {:error, _} = err -> err
      end
    end)
  end

  defp validate_channel_name(channel) do
    cond do
      channel == "" -> {:error, "events-channels entries cannot be empty"}
      byte_size(channel) > 63 -> {:error, "events-channels entries cannot exceed 63 bytes"}
      String.contains?(channel, <<0>>) -> {:error, "events-channels entries cannot contain null bytes"}
      String.contains?(channel, "\"") -> {:error, "events-channels entries cannot contain double quotes"}
      true -> :ok
    end
  end

  @doc """
  `events-path` is the reserved top-level path segment for the SSE endpoint,
  so it must be non-empty and must not contain `/`.
  """
  @spec validate_events_path(String.t()) :: :ok | {:error, String.t()}
  def validate_events_path(path) when is_binary(path) do
    cond do
      path == "" -> {:error, "events-path cannot be empty"}
      String.contains?(path, "/") -> {:error, "events-path must be a single path segment (no '/')"}
      true -> :ok
    end
  end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test test/bier/events_config_test.exs`
Expected: PASS (6 tests).

- [ ] **Step 6: Format and commit**

```bash
mix format
git add lib/bier.ex lib/bier/config.ex test/bier/events_config_test.exs
git commit -m "feat(#81): events_* config surface for the SSE realtime endpoint"
```

---

### Task 2: `Bier.Events.SSE` frame encoding

**Files:**
- Create: `lib/bier/events/sse.ex`
- Test: `test/bier/events/sse_test.exs` (new file)

**Interfaces:**
- Consumes: nothing.
- Produces: `Bier.Events.SSE.preamble/0 :: iodata()`, `Bier.Events.SSE.heartbeat/0 :: iodata()`, `Bier.Events.SSE.frame(channel :: String.t(), payload :: String.t()) :: iodata()`. Used by `Bier.Events` (Task 6).

- [ ] **Step 1: Write the failing test**

Create `test/bier/events/sse_test.exs`:

```elixir
defmodule Bier.Events.SSETest do
  use ExUnit.Case, async: true

  alias Bier.Events.SSE

  defp bin(iodata), do: IO.iodata_to_binary(iodata)

  test "frame/2 sets the channel as the SSE event name and the payload verbatim" do
    assert bin(SSE.frame("chat", ~s({"msg":"hi"}))) ==
             "event: chat\ndata: {\"msg\":\"hi\"}\n\n"
  end

  test "frame/2 splits multi-line payloads across data: lines" do
    assert bin(SSE.frame("chat", "line1\nline2")) ==
             "event: chat\ndata: line1\ndata: line2\n\n"
  end

  test "frame/2 emits a data: line for an empty payload so the client event fires" do
    assert bin(SSE.frame("chat", "")) == "event: chat\ndata: \n\n"
  end

  test "heartbeat/0 is an SSE comment" do
    assert bin(SSE.heartbeat()) == ": keepalive\n\n"
  end

  test "preamble/0 carries the retry hint and a connected comment" do
    assert bin(SSE.preamble()) == "retry: 3000\n: connected\n\n"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/bier/events/sse_test.exs`
Expected: FAIL — `Bier.Events.SSE` is undefined.

- [ ] **Step 3: Implement the module**

Create `lib/bier/events/sse.ex`:

```elixir
defmodule Bier.Events.SSE do
  @moduledoc """
  Pure Server-Sent Events wire encoding for the realtime events endpoint.

  Frames map a Postgres NOTIFY onto SSE's native fields: the channel name is
  the `event:` field and the payload is carried verbatim in `data:` lines —
  no envelope is invented. A payload containing newlines is split across
  consecutive `data:` lines per the SSE spec, which clients reassemble
  losslessly (joined with `\\n`).
  """

  @retry_ms 3000

  @doc "Opening bytes of every stream: reconnect hint + a comment frame."
  @spec preamble() :: iodata()
  def preamble, do: "retry: #{@retry_ms}\n: connected\n\n"

  @doc "Keepalive comment written after a configured interval of silence."
  @spec heartbeat() :: iodata()
  def heartbeat, do: ": keepalive\n\n"

  @doc "One event frame: `event:` = channel, `data:` = payload verbatim."
  @spec frame(String.t(), String.t()) :: iodata()
  def frame(channel, payload) do
    data =
      payload
      |> String.split("\n")
      |> Enum.map(&["data: ", &1, "\n"])

    ["event: ", channel, "\n", data, "\n"]
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/bier/events/sse_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 5: Format and commit**

```bash
mix format
git add lib/bier/events/sse.ex test/bier/events/sse_test.exs
git commit -m "feat(#81): SSE frame encoding for realtime events"
```

---

### Task 3: `Bier.Events.Registry` fan-out + application wiring

**Files:**
- Create: `lib/bier/events/registry.ex`
- Modify: `lib/bier/application.ex:12` (children list)
- Test: `test/bier/events/registry_test.exs` (new file)

**Interfaces:**
- Consumes: stdlib `Registry`.
- Produces: `Bier.Events.Registry.register(instance :: term(), channel :: String.t()) :: :ok` (registers the CALLING process), `Bier.Events.Registry.broadcast(instance, channel, payload :: String.t()) :: non_neg_integer()` (sends `{:bier_event, channel, payload}` to each subscriber, returns how many), `Bier.Events.Registry.subscriber_count(instance, channel) :: non_neg_integer()`. Used by the Listener (Task 5) and the request handler (Task 6). The registry process is named `Bier.Events.Registry` and started by `Bier.Application`, so it is always up in tests.

- [ ] **Step 1: Write the failing test**

Create `test/bier/events/registry_test.exs`:

```elixir
defmodule Bier.Events.RegistryTest do
  use ExUnit.Case, async: true

  alias Bier.Events.Registry, as: EventsRegistry

  test "register + broadcast delivers {:bier_event, channel, payload} to subscribers" do
    instance = :"events_reg_#{System.unique_integer([:positive])}"
    assert :ok = EventsRegistry.register(instance, "chat")

    assert EventsRegistry.broadcast(instance, "chat", "hello") == 1
    assert_receive {:bier_event, "chat", "hello"}
  end

  test "broadcast only reaches the matching instance and channel" do
    instance = :"events_reg_#{System.unique_integer([:positive])}"
    other = :"events_reg_#{System.unique_integer([:positive])}"
    assert :ok = EventsRegistry.register(instance, "chat")

    assert EventsRegistry.broadcast(instance, "jobs", "x") == 0
    assert EventsRegistry.broadcast(other, "chat", "x") == 0
    refute_receive {:bier_event, _, _}, 50
  end

  test "entries are cleaned up when the subscriber dies" do
    instance = :"events_reg_#{System.unique_integer([:positive])}"

    {pid, ref} =
      spawn_monitor(fn ->
        EventsRegistry.register(instance, "chat")

        receive do
          :stop -> :ok
        end
      end)

    # Wait until the spawned process has registered.
    wait_until(fn -> EventsRegistry.subscriber_count(instance, "chat") == 1 end)

    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    wait_until(fn -> EventsRegistry.subscriber_count(instance, "chat") == 0 end)
  end

  defp wait_until(fun, retries \\ 100) do
    cond do
      fun.() -> :ok
      retries == 0 -> flunk("condition never became true")
      true ->
        Process.sleep(10)
        wait_until(fun, retries - 1)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/bier/events/registry_test.exs`
Expected: FAIL — `Bier.Events.Registry` is undefined.

- [ ] **Step 3: Implement the module and start it in the application**

Create `lib/bier/events/registry.ex`:

```elixir
defmodule Bier.Events.Registry do
  @moduledoc """
  Node-shared pub/sub registry for the realtime events endpoint.

  A duplicate-keys `Registry` (mirroring `Bier.Registry`'s role as shared
  infrastructure) whose entries are keyed `{instance_name, channel}`. SSE
  subscriber processes register themselves; `Bier.Events.Listener` broadcasts
  each NOTIFY to the matching entries. Entries die with their process, so
  there is no unsubscribe bookkeeping.
  """

  @doc false
  def child_spec(_opts) do
    Registry.child_spec(keys: :duplicate, name: __MODULE__)
  end

  @doc "Subscribe the calling process to `channel` on `instance`."
  @spec register(term(), String.t()) :: :ok
  def register(instance, channel) do
    {:ok, _owner} = Registry.register(__MODULE__, {instance, channel}, nil)
    :ok
  end

  @doc """
  Send `{:bier_event, channel, payload}` to every subscriber of
  `{instance, channel}`; returns the number of subscribers reached.
  """
  @spec broadcast(term(), String.t(), String.t()) :: non_neg_integer()
  def broadcast(instance, channel, payload) do
    entries = Registry.lookup(__MODULE__, {instance, channel})
    for {pid, _value} <- entries, do: send(pid, {:bier_event, channel, payload})
    length(entries)
  end

  @doc "Number of live subscribers for `{instance, channel}`."
  @spec subscriber_count(term(), String.t()) :: non_neg_integer()
  def subscriber_count(instance, channel) do
    length(Registry.lookup(__MODULE__, {instance, channel}))
  end
end
```

In `lib/bier/application.ex`, change the children line:

```elixir
    children = [Bier.Registry, Bier.Events.Registry | standalone_children(System.get_env())]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/bier/events/registry_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Format and commit**

```bash
mix format
git add lib/bier/events/registry.ex lib/bier/application.ex test/bier/events/registry_test.exs
git commit -m "feat(#81): duplicate-keys events registry for SSE fan-out"
```

---

### Task 4: Telemetry helpers

**Files:**
- Modify: `lib/bier/telemetry.ex` (new event helpers + moduledoc entries, following the `request_start`/`request_stop` pattern already in the file)
- Test: `test/bier/events/telemetry_test.exs` (new file)

**Interfaces:**
- Consumes: `:telemetry`.
- Produces (used by Tasks 5–6):
  - `Bier.Telemetry.events_subscribe_start(metadata :: map()) :: integer()` — emits `[:bier, :events, :subscribe, :start]` with `%{system_time: ...}`, returns `System.monotonic_time()`.
  - `Bier.Telemetry.events_subscribe_stop(start :: integer(), delivered :: non_neg_integer(), metadata :: map()) :: :ok` — emits `[:bier, :events, :subscribe, :stop]` with `%{duration: ..., delivered: delivered}`.
  - `Bier.Telemetry.events_notification(subscribers :: non_neg_integer(), metadata :: map()) :: :ok` — emits `[:bier, :events, :notification]` with `%{subscribers: subscribers}`.
  - `Bier.Telemetry.events_listener(status :: :connected | :disconnected, metadata :: map()) :: :ok` — emits `[:bier, :events, :listener]` with `%{count: 1}` and `:status` merged into metadata.

- [ ] **Step 1: Write the failing test**

Create `test/bier/events/telemetry_test.exs`:

```elixir
defmodule Bier.Events.TelemetryTest do
  use ExUnit.Case, async: false

  setup do
    handler_id = "events-telemetry-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach_many(
      handler_id,
      [
        [:bier, :events, :subscribe, :start],
        [:bier, :events, :subscribe, :stop],
        [:bier, :events, :notification],
        [:bier, :events, :listener]
      ],
      fn event, measurements, metadata, _config ->
        send(parent, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "subscribe start/stop span with delivered count" do
    meta = %{instance: :t, channels: ["chat"]}
    start = Bier.Telemetry.events_subscribe_start(meta)
    assert is_integer(start)

    assert_receive {:telemetry, [:bier, :events, :subscribe, :start], %{system_time: _}, ^meta}

    :ok = Bier.Telemetry.events_subscribe_stop(start, 3, meta)

    assert_receive {:telemetry, [:bier, :events, :subscribe, :stop],
                    %{duration: duration, delivered: 3}, ^meta}

    assert duration >= 0
  end

  test "notification carries the subscriber count" do
    :ok = Bier.Telemetry.events_notification(2, %{instance: :t, channel: "chat"})

    assert_receive {:telemetry, [:bier, :events, :notification], %{subscribers: 2},
                    %{instance: :t, channel: "chat"}}
  end

  test "listener status events" do
    :ok = Bier.Telemetry.events_listener(:connected, %{instance: :t})

    assert_receive {:telemetry, [:bier, :events, :listener], %{count: 1},
                    %{instance: :t, status: :connected}}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/bier/events/telemetry_test.exs`
Expected: FAIL — `Bier.Telemetry.events_subscribe_start/1` is undefined.

- [ ] **Step 3: Implement the helpers**

In `lib/bier/telemetry.ex`, add module attributes next to the existing event-name attributes:

```elixir
  @events_subscribe_start [:bier, :events, :subscribe, :start]
  @events_subscribe_stop [:bier, :events, :subscribe, :stop]
  @events_notification [:bier, :events, :notification]
  @events_listener [:bier, :events, :listener]
```

Add the helpers (near `request_start`/`request_stop`, matching their style):

```elixir
  @doc """
  Start of an SSE events subscription (`[:bier, :events, :subscribe, :start]`).
  Returns the monotonic start time to pass to `events_subscribe_stop/3`.
  Metadata: `:instance`, `:channels`.
  """
  def events_subscribe_start(metadata) do
    start = System.monotonic_time()
    :telemetry.execute(@events_subscribe_start, %{system_time: System.system_time()}, metadata)
    start
  end

  @doc """
  End of an SSE events subscription (`[:bier, :events, :subscribe, :stop]`).
  Measurements: `:duration` (native units), `:delivered` (frames sent).
  """
  def events_subscribe_stop(start, delivered, metadata) do
    duration = System.monotonic_time() - start
    :telemetry.execute(@events_subscribe_stop, %{duration: duration, delivered: delivered}, metadata)
  end

  @doc """
  One NOTIFY fanned out to subscribers (`[:bier, :events, :notification]`).
  Measurement `:subscribers` is how many processes received it — a steady 0
  reveals an orphaned channel. Metadata: `:instance`, `:channel`.
  """
  def events_notification(subscribers, metadata) do
    :telemetry.execute(@events_notification, %{subscribers: subscribers}, metadata)
  end

  @doc """
  Events listener connectivity (`[:bier, :events, :listener]`): `:status` in
  metadata is `:connected` or `:disconnected`. Useful for alerting on gap
  windows (fire-and-forget delivery loses events while disconnected).
  """
  def events_listener(status, metadata) do
    :telemetry.execute(@events_listener, %{count: 1}, Map.put(metadata, :status, status))
  end
```

Also add the four event names to the module's `@moduledoc` where the existing events are listed, one line each, in the same list style as the file already uses.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/bier/events/telemetry_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Format and commit**

```bash
mix format
git add lib/bier/telemetry.ex test/bier/events/telemetry_test.exs
git commit -m "feat(#81): telemetry events for SSE subscriptions and listener"
```

---

### Task 5: `Bier.Events.Listener` + supervision wiring

**Files:**
- Create: `lib/bier/events/listener.ex`
- Modify: `lib/bier.ex` (`init/1` children ~line 488, new `events_children/1`)
- Test: `test/bier/events/listener_test.exs` (new file)

**Interfaces:**
- Consumes: `Bier.postgrex_opts/1`, `Bier.Registry.via/2`, `Bier.Events.Registry.broadcast/3` (Task 3), `Bier.Telemetry.events_notification/2` + `events_listener/2` (Task 4), `%Bier.Config{events_channels: ...}` (Task 1).
- Produces: a supervised GenServer registered at `Bier.Registry.via(name, Bier.Events.Listener)` that LISTENs on every allowlisted channel and broadcasts notifications. `Bier` supervisor starts it iff `events_channels != []`.

- [ ] **Step 1: Write the failing test**

Create `test/bier/events/listener_test.exs`:

```elixir
defmodule Bier.Events.ListenerTest do
  @moduledoc """
  Boots the events listener against the bier_test DB (loaded by the mix test
  alias) and drives it with pg_notify. Not async: real DB connections.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  defp config(channels) do
    opts =
      [
        name: :"events_listener_#{System.unique_integer([:positive])}",
        events_channels: channels
      ] ++ Bier.ConformanceServer.base_opts()

    Bier.Config.new!(opts, Bier.schema())
  end

  defp notify(channel, payload) do
    conf = config([])
    {:ok, conn} = Postgrex.start_link(Keyword.drop(Bier.postgrex_opts(conf), [:name, :pool_size]))
    Postgrex.query!(conn, "SELECT pg_notify($1, $2)", [channel, payload])
    GenServer.stop(conn)
  end

  test "broadcasts NOTIFY payloads to registered subscribers" do
    conf = config(["events_it_chat"])
    pid = start_supervised!({Bier.Events.Listener, conf})
    wait_until_connected(pid)

    :ok = Bier.Events.Registry.register(conf.name, "events_it_chat")
    notify("events_it_chat", "hello")

    assert_receive {:bier_event, "events_it_chat", "hello"}, 2_000
  end

  test "reconnects and re-LISTENs after losing the notifications connection" do
    conf = config(["events_it_chat"])
    pid = start_supervised!({Bier.Events.Listener, conf})
    wait_until_connected(pid)

    :ok = Bier.Events.Registry.register(conf.name, "events_it_chat")

    %{notifications: notif} = :sys.get_state(pid)
    Process.exit(notif, :kill)

    # Backoff starts at 500ms; after reconnect the LISTEN must be re-issued.
    wait_until_connected(pid, 200)
    notify("events_it_chat", "after-reconnect")

    assert_receive {:bier_event, "events_it_chat", "after-reconnect"}, 2_000
  end

  defp wait_until_connected(pid, retries \\ 100) do
    case :sys.get_state(pid) do
      %{notifications: notif} when is_pid(notif) ->
        :ok

      _ when retries > 0 ->
        Process.sleep(20)
        wait_until_connected(pid, retries - 1)

      state ->
        flunk("listener never connected: #{inspect(state)}")
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/bier/events/listener_test.exs`
Expected: FAIL — `Bier.Events.Listener` is undefined.

- [ ] **Step 3: Implement the listener**

Create `lib/bier/events/listener.ex`:

```elixir
defmodule Bier.Events.Listener do
  @moduledoc """
  Per-instance LISTEN connection for the realtime events endpoint.

  Subscribes to every channel in `events_channels` on one dedicated
  `Postgrex.Notifications` connection and fans each notification out to SSE
  subscribers via `Bier.Events.Registry.broadcast/3`.

  Connection ownership mirrors `Bier.SchemaCacheListener`: the connection is
  started with `auto_reconnect: false` under `trap_exit`, and on loss the
  listener stays alive and retries with exponential backoff, so a database
  outage never crash-loops the instance's supervisor. Delivery is
  fire-and-forget by contract — notifications sent while disconnected are
  lost and no catch-up is attempted (unlike the schema-cache listener, there
  is nothing to reload).
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
    {:ok, %{conf: conf, notifications: nil, backoff: @initial_backoff}, {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, state), do: connect(state)

  @impl GenServer
  def handle_info(:connect, state), do: connect(state)

  def handle_info({:notification, _pid, _ref, channel, payload}, %{conf: conf} = state) do
    subscribers = Bier.Events.Registry.broadcast(conf.name, channel, payload)
    Bier.Telemetry.events_notification(subscribers, %{instance: conf.name, channel: channel})
    {:noreply, state}
  end

  def handle_info({:EXIT, pid, reason}, %{notifications: pid, conf: conf} = state) do
    Logger.warning(
      "Bier events listener for #{inspect(conf.name)} lost its LISTEN " <>
        "connection: #{inspect(reason)}"
    )

    Bier.Telemetry.events_listener(:disconnected, %{instance: conf.name})
    {:noreply, schedule_reconnect(%{state | notifications: nil})}
  end

  # An EXIT from a connection already replaced after an earlier failure.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  # The LISTEN connection cannot go through the request pool; run a dedicated
  # Postgrex.Notifications connection built from the instance options.
  defp connect(%{conf: conf} = state) do
    opts =
      conf
      |> Bier.postgrex_opts()
      |> Keyword.drop([:name, :pool_size])
      |> Keyword.merge(sync_connect: true, auto_reconnect: false)

    case Postgrex.Notifications.start_link(opts) do
      {:ok, pid} ->
        case listen_all(pid, conf.events_channels) do
          :ok ->
            Bier.Telemetry.events_listener(:connected, %{instance: conf.name})
            {:noreply, %{state | notifications: pid, backoff: @initial_backoff}}

          {:error, other} ->
            Logger.warning(
              "Bier events listener for #{inspect(conf.name)} could not LISTEN " <>
                "(retrying in #{state.backoff}ms): #{inspect(other)}"
            )

            # Not a real subscription — drop the connection and retry. We stay
            # linked and do NOT touch state.notifications: a late :EXIT from
            # this pid lands on the catch-all clause above and is ignored.
            Process.exit(pid, :kill)
            {:noreply, schedule_reconnect(state)}
        end

      {:error, reason} ->
        Logger.warning(
          "Bier events listener for #{inspect(conf.name)} cannot reach the " <>
            "database (retrying in #{state.backoff}ms): #{inspect(reason)}"
        )

        {:noreply, schedule_reconnect(state)}
    end
  end

  # Every allowlisted channel must subscribe; the first failure aborts the
  # attempt (all-or-retry keeps the LISTEN set consistent with the config).
  defp listen_all(pid, channels) do
    Enum.reduce_while(channels, :ok, fn channel, :ok ->
      case safe_listen(pid, channel) do
        {:ok, _ref} -> {:cont, :ok}
        other -> {:halt, {:error, other}}
      end
    end)
  end

  # `listen/3` returns `{:ok, ref}` once subscribed, or `{:eventually, ref}`
  # when the connection isn't actually up — not a real subscription either.
  # It can also raise if the fresh connection died between `start_link/1`
  # returning and this call; caught so a lost race becomes a retry.
  defp safe_listen(pid, channel) do
    Postgrex.Notifications.listen(pid, channel)
  catch
    :exit, reason -> {:exit, reason}
  end

  defp schedule_reconnect(state) do
    Process.send_after(self(), :connect, state.backoff)
    %{state | backoff: min(state.backoff * 2, @max_backoff)}
  end
end
```

- [ ] **Step 4: Wire into the `Bier` supervisor**

In `lib/bier.ex` `init/1`, change the trailing children concatenation from:

```elixir
        ] ++ listener_children(conf) ++ admin_children(conf)
```

to:

```elixir
        ] ++ listener_children(conf) ++ events_children(conf) ++ admin_children(conf)
```

and add next to `listener_children/1`:

```elixir
  # When any events_channels are configured, run the SSE events listener —
  # a second dedicated LISTEN connection, deliberately separate from the
  # schema-cache listener so user-facing streaming never couples to reload
  # semantics. It owns its DB connection and retries with internal backoff,
  # so a database outage never builds restart pressure on this supervisor.
  defp events_children(%Bier.Config{events_channels: []}), do: []

  defp events_children(%Bier.Config{} = conf), do: [{Bier.Events.Listener, conf}]
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/bier/events/listener_test.exs`
Expected: PASS (2 tests). The reconnect test takes ~1s (backoff).

- [ ] **Step 6: Format and commit**

```bash
mix format
git add lib/bier/events/listener.ex lib/bier.ex test/bier/events/listener_test.exs
git commit -m "feat(#81): per-instance LISTEN fan-out listener for realtime events"
```

---

### Task 6: Request handler, routing, and error envelopes

**Files:**
- Create: `lib/bier/events.ex`
- Modify: `lib/bier/plugs/action_controller.ex:51-71` (`dispatch/3`)
- Modify: `lib/bier/plugs/fallback_controller.ex` (two new clauses, before the catch-all)
- Test: `test/bier/events_http_test.exs` (new file)

**Interfaces:**
- Consumes: `Bier.Events.SSE` (Task 2), `Bier.Events.Registry.register/2` (Task 3), telemetry helpers (Task 4), `Bier.Plugs.ActionController.maybe_auth/2` (existing, public `@doc false`), `config.events_*` (Task 1).
- Produces: `Bier.Events.handles?(conn, config) :: boolean()` and `Bier.Events.handle(conn, config) :: Plug.Conn.t() | {:error, term()}`. Error reasons `{:error, :events_missing_channel}` (→ 400 `BIER002`) and `{:error, {:events_unknown_channel, channel}}` (→ 404 `BIER001`) rendered by FallbackController.

- [ ] **Step 1: Write the failing tests (error paths + single-channel happy path)**

Create `test/bier/events_http_test.exs`:

```elixir
defmodule Bier.EventsHttpTest do
  @moduledoc """
  Boots a dedicated Bier instance with events enabled and exercises the SSE
  endpoint over real HTTP. Streaming assertions use a raw :gen_tcp client
  because the response intentionally never ends. Not async: real ports + DB.
  """
  use ExUnit.Case, async: false

  alias Bier.TestPorts

  @moduletag :integration

  @channels ["events_it_chat", "events_it_jobs"]

  setup do
    port = TestPorts.free_port()
    name = :"events_http_#{System.unique_integer([:positive])}"

    opts =
      [
        name: name,
        router: [port: port, scheme: :http],
        events_channels: @channels,
        events_heartbeat_interval: 50
      ] ++ Bier.ConformanceServer.base_opts()

    start_supervised!({Bier, opts})
    TestPorts.wait_until_listening(port)

    %{port: port, name: name}
  end

  # ---- error paths (plain requests, no streaming needed) -------------------

  test "GET /events without a channel param is 400 BIER002", %{port: port} do
    resp = Req.get!("http://127.0.0.1:#{port}/events", retry: false)
    assert resp.status == 400
    assert resp.body["code"] == "BIER002"
  end

  test "GET /events with a channel outside the allowlist is 404 BIER001", %{port: port} do
    resp = Req.get!("http://127.0.0.1:#{port}/events?channel=nope", retry: false)
    assert resp.status == 404
    assert resp.body["code"] == "BIER001"
    assert resp.body["details"] =~ "nope"
  end

  test "one bad channel among good ones is still 404", %{port: port} do
    resp =
      Req.get!("http://127.0.0.1:#{port}/events?channel=events_it_chat,nope", retry: false)

    assert resp.status == 404
    assert resp.body["code"] == "BIER001"
  end

  test "POST /events is 405", %{port: port} do
    resp = Req.post!("http://127.0.0.1:#{port}/events?channel=events_it_chat", retry: false)
    assert resp.status == 405
  end

  test "an Accept that excludes text/event-stream is 406", %{port: port} do
    resp =
      Req.get!("http://127.0.0.1:#{port}/events?channel=events_it_chat",
        headers: [accept: "application/xml"],
        retry: false
      )

    assert resp.status == 406
    assert resp.body["code"] == "PGRST107"
  end

  test "other relations keep resolving normally while events are enabled", %{port: port} do
    # The events instance reserves only /events; everything else is untouched.
    resp = Req.get!("http://127.0.0.1:#{port}/complex_items?select=id&limit=1", retry: false)
    assert resp.status == 200
  end

  # ---- streaming happy path -------------------------------------------------

  test "subscribing streams NOTIFY payloads as SSE frames", %{port: port, name: name} do
    sock = connect_sse(port, "/events?channel=events_it_chat")
    head = recv_until(sock, ": connected")
    assert head =~ "200 OK"
    assert head =~ "text/event-stream"
    assert head =~ "retry: 3000"

    wait_until(fn -> Bier.Events.Registry.subscriber_count(name, "events_it_chat") == 1 end)
    notify(name, "events_it_chat", ~s({"msg":"hi"}))

    frames = recv_until(sock, "data:")
    assert frames =~ "event: events_it_chat"
    assert frames =~ ~s(data: {"msg":"hi"})

    :gen_tcp.close(sock)
  end

  # ---- helpers ---------------------------------------------------------------

  defp connect_sse(port, path) do
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 1_000)

    :ok =
      :gen_tcp.send(
        sock,
        "GET #{path} HTTP/1.1\r\nhost: 127.0.0.1\r\naccept: text/event-stream\r\n\r\n"
      )

    sock
  end

  # Collect chunked bytes until the accumulated stream contains `pattern`.
  # Chunked transfer framing (sizes/CRLFs) is tolerated by substring matching.
  defp recv_until(sock, pattern, acc \\ "") do
    if acc =~ pattern do
      acc
    else
      case :gen_tcp.recv(sock, 0, 3_000) do
        {:ok, data} -> recv_until(sock, pattern, acc <> data)
        {:error, reason} -> flunk("waiting for #{inspect(pattern)}, got #{inspect(acc)} (#{inspect(reason)})")
      end
    end
  end

  defp notify(name, channel, payload) do
    pool = Bier.Registry.via(name, Postgrex)
    Postgrex.query!(pool, "SELECT pg_notify($1, $2)", [channel, payload])
  end

  defp wait_until(fun, retries \\ 100) do
    cond do
      fun.() -> :ok
      retries == 0 -> flunk("condition never became true")
      true ->
        Process.sleep(10)
        wait_until(fun, retries - 1)
    end
  end
end
```

Note: the `projects` relation exists in the `test` schema of the conformance fixture DB (it is used all over `spec/conformance`), and `base_opts/0` exposes `test` as the default schema.

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/bier/events_http_test.exs`
Expected: FAIL — currently `/events` resolves as an unknown relation (404 PGRST205), so the BIER002/BIER001/streaming assertions all fail.

- [ ] **Step 3: Implement `Bier.Events`**

Create `lib/bier/events.ex`:

```elixir
defmodule Bier.Events do
  @moduledoc """
  Request handler for the realtime events endpoint (`GET /<events_path>`).

  Bridges Postgres NOTIFY to Server-Sent Events: validates the requested
  channels against the `events_channels` allowlist, authenticates with the
  instance's standard JWT gate, then holds the connection open inside the
  Bandit connection process, relaying `{:bier_event, channel, payload}`
  messages from `Bier.Events.Listener` as SSE frames.

  Delivery is fire-and-forget (at-most-once): NOTIFY is ephemeral, so events
  fired while a client is disconnected are lost. Clients get a `retry:` hint
  and periodic keepalive comments; reconnection does not replay.
  """

  import Plug.Conn

  alias Bier.Events.SSE

  @doc """
  True when this request targets the events endpoint: the feature is enabled
  (non-empty allowlist) and the path is exactly the configured segment.
  """
  @spec handles?(Plug.Conn.t(), Bier.Config.t()) :: boolean()
  def handles?(%Plug.Conn{path_info: [segment]}, config) do
    config.events_channels != [] and segment == config.events_path
  end

  def handles?(_conn, _config), do: false

  @doc """
  Handle a subscription request. Returns the streaming `Plug.Conn` (which
  only comes back once the client disconnects) or an `{:error, reason}` for
  `Bier.Plugs.FallbackController`.
  """
  @spec handle(Plug.Conn.t(), Bier.Config.t()) :: Plug.Conn.t() | {:error, term()}
  def handle(%Plug.Conn{method: "GET"} = conn, config) do
    with {:ok, channels} <- parse_channels(conn),
         :ok <- authorize(channels, config),
         {:ok, conn} <- Bier.Plugs.ActionController.maybe_auth(bearer_fallback(conn), config),
         :ok <- negotiate(conn) do
      stream(conn, config, channels)
    end
  end

  def handle(_conn, _config), do: {:error, :method_not_allowed}

  # Collect every `channel` query param, each split on commas, deduplicated.
  # Repeated params and comma lists are equivalent. No usable channel -> 400.
  defp parse_channels(conn) do
    channels =
      conn.query_string
      |> URI.query_decoder()
      |> Enum.flat_map(fn
        {"channel", value} -> String.split(value, ",", trim: true)
        _other -> []
      end)
      |> Enum.uniq()

    case channels do
      [] -> {:error, :events_missing_channel}
      channels -> {:ok, channels}
    end
  end

  defp authorize(channels, config) do
    case Enum.find(channels, &(&1 not in config.events_channels)) do
      nil -> :ok
      unknown -> {:error, {:events_unknown_channel, unknown}}
    end
  end

  # The browser EventSource API cannot set request headers, so this endpoint
  # (only) also accepts the JWT as an `access_token` query param. The header
  # wins when both are present; the fallback is materialized as a synthetic
  # Authorization header so Bier.Auth stays the single verification path.
  defp bearer_fallback(conn) do
    with [] <- get_req_header(conn, "authorization"),
         token when is_binary(token) and token != "" <- access_token(conn) do
      put_req_header(conn, "authorization", "Bearer " <> token)
    else
      _ -> conn
    end
  end

  defp access_token(conn) do
    conn.query_string
    |> URI.query_decoder()
    |> Enum.find_value(fn
      {"access_token", value} -> value
      _other -> nil
    end)
  end

  # The only producer here is text/event-stream; a missing Accept, a wildcard,
  # or text/* admits it. Anything else is PostgREST's 406 (PGRST107).
  defp negotiate(conn) do
    case get_req_header(conn, "accept") do
      [] -> :ok
      [accept | _] -> if accepts_event_stream?(accept), do: :ok, else: {:error, {:not_acceptable, accept}}
    end
  end

  defp accepts_event_stream?(accept) do
    accept
    |> String.split(",")
    |> Enum.map(fn entry -> entry |> String.split(";") |> hd() |> String.trim() end)
    |> Enum.any?(&(&1 in ["*/*", "text/*", "text/event-stream", ""]))
  end

  defp stream(conn, config, channels) do
    metadata = %{instance: config.name, channels: channels}
    start = Bier.Telemetry.events_subscribe_start(metadata)

    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream; charset=utf-8")
      |> put_resp_header("cache-control", "no-store")
      # Stops buffering reverse proxies (nginx et al.) from absorbing frames.
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    case chunk(conn, SSE.preamble()) do
      {:ok, conn} ->
        Enum.each(channels, &Bier.Events.Registry.register(config.name, &1))
        loop(conn, config.events_heartbeat_interval, 0, start, metadata)

      {:error, _reason} ->
        finish(conn, 0, start, metadata)
    end
  end

  # Runs in the Bandit connection process. Registry entries die with it, so
  # there is no explicit unsubscribe. A failed write (client gone) ends the
  # loop; detection of a silent disconnect is bounded by the heartbeat.
  defp loop(conn, heartbeat, delivered, start, metadata) do
    receive do
      {:bier_event, channel, payload} ->
        case chunk(conn, SSE.frame(channel, payload)) do
          {:ok, conn} -> loop(conn, heartbeat, delivered + 1, start, metadata)
          {:error, _reason} -> finish(conn, delivered, start, metadata)
        end
    after
      heartbeat ->
        case chunk(conn, SSE.heartbeat()) do
          {:ok, conn} -> loop(conn, heartbeat, delivered, start, metadata)
          {:error, _reason} -> finish(conn, delivered, start, metadata)
        end
    end
  end

  defp finish(conn, delivered, start, metadata) do
    Bier.Telemetry.events_subscribe_stop(start, delivered, metadata)
    conn
  end
end
```

- [ ] **Step 4: Route to it from `ActionController` and render the new errors**

In `lib/bier/plugs/action_controller.ex`, `dispatch/3`, replace the final clause:

```elixir
      _ ->
        dispatch_relation(conn, config, relations)
```

with:

```elixir
      _ ->
        # The SSE events endpoint reserves its (configurable) segment only
        # while events_channels is non-empty; otherwise the segment resolves
        # as a relation exactly as before.
        if Bier.Events.handles?(conn, config) do
          Bier.Events.handle(conn, config)
        else
          dispatch_relation(conn, config, relations)
        end
```

In `lib/bier/plugs/fallback_controller.ex`, add BEFORE the `# ---- catch-all` clause:

```elixir
  # ---- realtime events endpoint (Bier-specific BIER* codes) ----------------
  def call(conn, {:error, :events_missing_channel}) do
    error(conn, 400, %{
      code: "BIER002",
      message: "Missing channel query parameter",
      details: nil,
      hint: "Subscribe with ?channel=<name> (comma-separate or repeat for several)"
    })
  end

  def call(conn, {:error, {:events_unknown_channel, channel}}) do
    error(conn, 404, %{
      code: "BIER001",
      message: "Unknown event channel",
      details: "Channel '#{channel}' is not exposed",
      hint: "Expose it by adding the channel to events_channels"
    })
  end
```

- [ ] **Step 5: Run the tests**

Run: `mix test test/bier/events_http_test.exs`
Expected: PASS (7 tests).

Also run the conformance suite to prove the feature is inert when disabled:
`mix test`
Expected: same pass/fail profile as `main` (no new failures).

- [ ] **Step 6: Format and commit**

```bash
mix format
git add lib/bier/events.ex lib/bier/plugs/action_controller.ex lib/bier/plugs/fallback_controller.ex test/bier/events_http_test.exs
git commit -m "feat(#81): SSE events endpoint - routing, auth gate, stream loop"
```

---

### Task 7: Streaming edge cases — multiplexing, heartbeat, disconnect cleanup, JWT

**Files:**
- Create: `test/bier/events_stream_test.exs` (new file)
- Modify (only if a test exposes a defect): `lib/bier/events.ex`

**Interfaces:**
- Consumes: everything from Tasks 1–6. `Bier.JWT` verifies HS256; tokens are hand-signed in the test with `:crypto.mac/4` (no new deps).
- Produces: locked-in behavior for multiplexed frames, heartbeats, registry cleanup on disconnect, and `access_token` auth.

- [ ] **Step 1: Write the tests**

Create `test/bier/events_stream_test.exs`:

```elixir
defmodule Bier.EventsStreamTest do
  @moduledoc """
  Streaming edge cases for the SSE events endpoint: multiplexing, heartbeats,
  disconnect cleanup, and JWT auth (header + access_token fallback). Raw
  :gen_tcp client, dedicated instances, not async.
  """
  use ExUnit.Case, async: false

  alias Bier.TestPorts

  @moduletag :integration

  @secret String.duplicate("s", 32)

  defp boot(extra_opts) do
    port = TestPorts.free_port()
    name = :"events_stream_#{System.unique_integer([:positive])}"

    opts =
      [
        name: name,
        router: [port: port, scheme: :http],
        events_channels: ["events_it_chat", "events_it_jobs"],
        events_heartbeat_interval: 50
      ] ++ extra_opts ++ Bier.ConformanceServer.base_opts()

    start_supervised!({Bier, opts})
    TestPorts.wait_until_listening(port)
    {port, name}
  end

  test "one connection multiplexes several channels via the event: field" do
    {port, name} = boot([])
    sock = connect_sse(port, "/events?channel=events_it_chat,events_it_jobs")
    recv_until(sock, ": connected")

    wait_until(fn -> Bier.Events.Registry.subscriber_count(name, "events_it_jobs") == 1 end)

    notify(name, "events_it_chat", "one")
    notify(name, "events_it_jobs", "two")

    stream = recv_until(sock, "data: two")
    assert stream =~ "event: events_it_chat\ndata: one"
    assert stream =~ "event: events_it_jobs\ndata: two"

    :gen_tcp.close(sock)
  end

  test "keepalive comments arrive during silence" do
    {port, name} = boot([])
    sock = connect_sse(port, "/events?channel=events_it_chat")
    recv_until(sock, ": connected")
    _ = name

    assert recv_until(sock, ": keepalive") =~ ": keepalive"
    :gen_tcp.close(sock)
  end

  test "closing the socket removes the registry entries" do
    {port, name} = boot([])
    sock = connect_sse(port, "/events?channel=events_it_chat")
    recv_until(sock, ": connected")

    wait_until(fn -> Bier.Events.Registry.subscriber_count(name, "events_it_chat") == 1 end)
    :gen_tcp.close(sock)

    # Detection is bounded by the 50ms heartbeat: the next write fails and the
    # connection process exits, taking its registry entries with it.
    wait_until(fn -> Bier.Events.Registry.subscriber_count(name, "events_it_chat") == 0 end)
  end

  test "with a jwt_secret and no anon role, a tokenless subscribe is 401" do
    {port, _name} = boot(jwt_secret: @secret)

    resp = Req.get!("http://127.0.0.1:#{port}/events?channel=events_it_chat", retry: false)
    assert resp.status == 401
    assert resp.body["code"] == "PGRST302"
  end

  test "a valid JWT via the access_token query param opens the stream" do
    {port, _name} = boot(jwt_secret: @secret)
    token = sign_hs256(%{"role" => "events_subscriber"}, @secret)

    sock = connect_sse(port, "/events?channel=events_it_chat&access_token=#{token}")
    assert recv_until(sock, ": connected") =~ "200 OK"
    :gen_tcp.close(sock)
  end

  test "an invalid access_token is rejected like a bad bearer token" do
    {port, _name} = boot(jwt_secret: @secret)

    resp =
      Req.get!(
        "http://127.0.0.1:#{port}/events?channel=events_it_chat&access_token=not.a.jwt",
        retry: false
      )

    assert resp.status == 401
    assert resp.body["code"] == "PGRST301"
  end

  # ---- helpers (same shape as events_http_test) -----------------------------

  defp connect_sse(port, path) do
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 1_000)

    :ok =
      :gen_tcp.send(
        sock,
        "GET #{path} HTTP/1.1\r\nhost: 127.0.0.1\r\naccept: text/event-stream\r\n\r\n"
      )

    sock
  end

  defp recv_until(sock, pattern, acc \\ "") do
    if acc =~ pattern do
      acc
    else
      case :gen_tcp.recv(sock, 0, 3_000) do
        {:ok, data} -> recv_until(sock, pattern, acc <> data)
        {:error, reason} -> flunk("waiting for #{inspect(pattern)}, got #{inspect(acc)} (#{inspect(reason)})")
      end
    end
  end

  defp notify(name, channel, payload) do
    pool = Bier.Registry.via(name, Postgrex)
    Postgrex.query!(pool, "SELECT pg_notify($1, $2)", [channel, payload])
  end

  defp wait_until(fun, retries \\ 100) do
    cond do
      fun.() -> :ok
      retries == 0 -> flunk("condition never became true")
      true ->
        Process.sleep(10)
        wait_until(fun, retries - 1)
    end
  end

  defp sign_hs256(claims, secret) do
    encode = fn map -> map |> Bier.json_library().encode!() |> Base.url_encode64(padding: false) end
    header = encode.(%{"alg" => "HS256", "typ" => "JWT"})
    payload = encode.(claims)

    signature =
      :crypto.mac(:hmac, :sha256, secret, header <> "." <> payload)
      |> Base.url_encode64(padding: false)

    header <> "." <> payload <> "." <> signature
  end
end
```

- [ ] **Step 2: Run the tests**

Run: `mix test test/bier/events_stream_test.exs`
Expected: PASS (6 tests). These exercise behavior already implemented in Task 6; a failure here is a defect in `lib/bier/events.ex` — fix it there (never adjust the assertion to match broken behavior) and note what changed in the commit message.

- [ ] **Step 3: Format and commit**

```bash
mix format
git add test/bier/events_stream_test.exs lib/bier/events.ex
git commit -m "test(#81): streaming edge cases - multiplex, heartbeat, cleanup, JWT"
```

(Drop `lib/bier/events.ex` from the `git add` if Step 2 required no fix.)

---

### Task 8: Documentation — guide, tutorial chapter, ExDoc wiring, CHANGELOG

**Files:**
- Create: `docs/guides/realtime_events.md`
- Create: `docs/tutorials/realtime.md`
- Modify: `mix.exs` (docs `extras`, ~line 71)
- Modify: `CHANGELOG.md` (entry under the unreleased/topmost section, matching the file's existing style)

**Interfaces:**
- Consumes: the shipped behavior from Tasks 1–7.
- Produces: rendered ExDoc pages (Tutorials + Reference groups pick the files up via the existing `groups_for_extras` regexes).

- [ ] **Step 1: Write the guide**

Create `docs/guides/realtime_events.md`:

```markdown
# Realtime events (SSE)

Bier can bridge PostgreSQL's `LISTEN`/`NOTIFY` to browsers and other HTTP
clients as [Server-Sent Events](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events).
Anything in your database that runs `NOTIFY` — a trigger, a function, plain
application code — becomes a live event stream, with no extra service to
deploy. PostgREST has no equivalent.

## Configuration

The feature is off by default. Enabling it means allowlisting channels:

    children = [
      {Bier,
       name: MyApp.Bier,
       router: [port: 4040, scheme: :http],
       events_channels: ["orders", "chat"]}
    ]

| Option | Default | Meaning |
|---|---|---|
| `events_channels` | `[]` | Channels clients may subscribe to. Empty = feature disabled. |
| `events_path` | `"events"` | Reserved top-level path segment. Change it if you expose a relation named `events`. |
| `events_heartbeat_interval` | `15_000` | ms of silence before a `: keepalive` comment is sent. |

While enabled, `GET /<events_path>` no longer resolves as a relation — pick
a different `events_path` if that collides with one of your tables.

## Subscribing

One connection can multiplex any number of allowlisted channels; each NOTIFY
arrives with the channel name in SSE's native `event:` field and the payload
verbatim in `data:`.

    curl -N "http://localhost:4040/events?channel=orders,chat"

    event: orders
    data: {"id": 42}

In the browser:

    const es = new EventSource("/events?channel=orders,chat");
    es.addEventListener("orders", (e) => console.log(JSON.parse(e.data)));
    es.addEventListener("chat", (e) => console.log(e.data));

Emit events from SQL:

    NOTIFY orders, '{"id": 42}';
    -- or, parameterizable:
    SELECT pg_notify('orders', json_build_object('id', new.id)::text);

## Authentication

The endpoint uses the instance's standard JWT gate: when `jwt_secret` or
`db_anon_role` is configured, subscriptions are authenticated exactly like
API requests. Because the browser `EventSource` API cannot set headers, this
endpoint also accepts the token as a query parameter — the `Authorization`
header wins when both are present:

    const es = new EventSource(`/events?channel=orders&access_token=${jwt}`);

Note that query strings tend to end up in server logs; prefer the
`Authorization` header for non-browser clients.

## Errors

Errors use the PostgREST envelope with Bier-specific codes:

| Status | Code | When |
|---|---|---|
| 400 | `BIER002` | No `channel` query parameter. |
| 404 | `BIER001` | A requested channel is not in `events_channels`. |
| 401 | `PGRST3xx` | JWT missing/invalid, same as the rest of the API. |
| 406 | `PGRST107` | `Accept` excludes `text/event-stream`. |
| 405 | `PGRST117` | Any method other than `GET`. |

## Delivery semantics and limits

Be aware of what `LISTEN`/`NOTIFY` actually guarantees — Bier does not
pretend otherwise:

  * **At-most-once.** Events fired while a client (or Bier's listener
    connection) is disconnected are lost. Clients receive a `retry:` hint and
    `EventSource` reconnects automatically, but nothing is replayed.
  * **8000-byte payloads.** Postgres rejects larger NOTIFY payloads. For big
    rows, notify a key and fetch the row through the regular API
    (see the tutorial for the pattern).
  * **Ordering** follows Postgres's notification queue per connection.

## Telemetry

  * `[:bier, :events, :subscribe, :start | :stop]` — one span per SSE
    connection (`:stop` carries `:duration` and `:delivered`).
  * `[:bier, :events, :notification]` — per NOTIFY, with the `:subscribers`
    count reached.
  * `[:bier, :events, :listener]` — `:status` of `:connected` /
    `:disconnected`; alert on this to spot gap windows.
```

- [ ] **Step 2: Write the tutorial chapter**

Create `docs/tutorials/realtime.md`:

```markdown
# Realtime: a live orders board

This chapter continues the brewery from [Getting started](getting-started.md)
(schema in `docs/tutorials/brewery.sql`). We'll push new orders to a browser
the moment they land, using nothing but a trigger and Bier's SSE endpoint.

## 1. Expose a channel

Add the allowlist to the Bier child spec:

    {Bier,
     name: Brewery.Bier,
     router: [port: 4040, scheme: :http],
     db_schemas: ["brewery"],
     events_channels: ["new_orders"]}

## 2. Notify on insert

The payload is a key, not the row — NOTIFY payloads are capped at 8000 bytes,
and sending just the id lets the client fetch exactly the columns it wants
through the API it already knows:

    create or replace function brewery.notify_new_order()
    returns trigger language plpgsql as $$
    begin
      perform pg_notify('new_orders', new.id::text);
      return new;
    end;
    $$;

    create trigger orders_notify
      after insert on brewery.orders
      for each row execute function brewery.notify_new_order();

## 3. Listen in the browser

    const es = new EventSource("/events?channel=new_orders");

    es.addEventListener("new_orders", async (e) => {
      const res = await fetch(`/orders?id=eq.${e.data}&select=id,beer,quantity`);
      const [order] = await res.json();
      renderRow(order); // your UI code
    });

## 4. Try it

    curl -X POST http://localhost:4040/orders \
      -H "content-type: application/json" \
      -d '{"beer": "Wobbly Boot IPA", "quantity": 2}'

The `new_orders` event fires, the browser fetches the row, and the board
updates — no polling, no extra realtime service.

For authentication, multiplexing several channels, delivery caveats, and
telemetry, see the [Realtime events guide](../guides/realtime_events.md).
```

Before committing, open `docs/tutorials/getting-started.md` and confirm the
table/column names used above (`brewery.orders`, `beer`, `quantity`) match the
tutorial's actual schema in `docs/tutorials/brewery.sql`; adjust the SQL and
curl examples to the real column names if they differ.

- [ ] **Step 3: Wire into ExDoc and CHANGELOG**

In `mix.exs` `docs`/`extras`, add after `"docs/tutorials/authentication.md",`:

```elixir
        "docs/tutorials/realtime.md",
```

and after `"docs/guides/observability.md",`:

```elixir
        "docs/guides/realtime_events.md",
```

In `CHANGELOG.md`, add under the unreleased/topmost section, matching the
file's existing bullet style:

```markdown
- Realtime events: config-gated SSE endpoint bridging Postgres LISTEN/NOTIFY
  (`events_channels`, `events_path`, `events_heartbeat_interval`) (#81).
```

- [ ] **Step 4: Verify docs build**

Run: `mix docs --warnings-as-errors`
Expected: exits 0, no warnings (broken links in the new pages would fail here).

- [ ] **Step 5: Format and commit**

```bash
mix format
git add docs/guides/realtime_events.md docs/tutorials/realtime.md mix.exs CHANGELOG.md
git commit -m "docs(#81): realtime events guide + brewery tutorial chapter"
```

---

### Task 9: Full gate + issue linkage

**Files:**
- No new files. Fixes only if a gate fails.

- [ ] **Step 1: Run every CI gate**

Run: `mix precommit`
Expected: all green — `deps.unlock --check-unused`, `format --check-formatted`, `hex.audit`, `compile --warnings-as-errors`, `credo --strict`, `docs --warnings-as-errors`, and the full test suite (conformance profile unchanged plus the new events tests). Fix anything that fails and amend/commit.

- [ ] **Step 2: Comment on issue #81**

```bash
gh issue comment 81 --repo milmazz/bier --body "Design spec: docs/superpowers/specs/2026-07-16-sse-realtime-events-design.md — implementation plan: docs/superpowers/plans/2026-07-16-sse-realtime-events.md (branch feat/81-sse-realtime-events)."
```

- [ ] **Step 3: Hand off**

Implementation complete on `feat/81-sse-realtime-events`. Do NOT merge or open a PR without explicit instruction — surface the branch for review (the superpowers:finishing-a-development-branch skill handles the options).
