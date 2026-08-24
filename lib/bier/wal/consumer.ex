defmodule Bier.Wal.Consumer do
  @moduledoc """
  The per-instance logical-replication consumer.

  Creates a TEMPORARY pgoutput slot against the operator's publication and
  streams it, assembling each transaction and delivering it at Commit: the
  events go into `Bier.Wal.Buffer` (for `Last-Event-ID` replay) and out to
  live subscribers via `Bier.Events.Registry`. Because the slot is
  temporary, a (re)start begins at the current LSN: once the new slot
  actually exists the Buffer generation is bumped and subscribers get an
  explicit `{:bier_wal_reset, ...}` rather than a silent gap — once per
  successful restart, never per failed slot-creation attempt. Transactions
  larger than `events_max_tx_events` are dropped the same announced way
  (`"transaction_too_large"`).

  A `TRUNCATE` can name several relations at once; `Bier.Wal.Render.data/3`
  renders one event per relation (`%{kind: :truncate, relation: rel}`,
  singular), so `deliver/4` fans a decoded truncate out into one event per
  member relation — each with its own cursor sequence and table key — and
  the per-transaction event cap counts every fanned-out event, not the
  single wire message.
  """

  use Postgrex.ReplicationConnection

  require Logger

  alias Bier.Events.Registry, as: Events
  alias Bier.Wal.{Buffer, Pgoutput}

  # Companion ceiling to `events_max_tx_events`, in accumulated payload
  # bytes. Not configurable: it is a process-heap backstop, not a tuning
  # knob — `events_max_tx_events` is the knob operators reason about.
  @max_tx_bytes 64 * 1024 * 1024

  def start_link(%Bier.Config{} = conf) do
    {pg_opts, _} =
      Keyword.split(Bier.postgrex_opts(conf), [
        :hostname,
        :port,
        :database,
        :username,
        :password,
        :ssl
      ])

    Postgrex.ReplicationConnection.start_link(
      __MODULE__,
      conf,
      pg_opts ++
        [
          auto_reconnect: true,
          # Postgrex defaults this to true, which runs the whole
          # connect/CREATE_REPLICATION_SLOT/START_REPLICATION chain inside
          # `init/1` with no timeout. CREATE_REPLICATION_SLOT ... LOGICAL
          # must reach a consistent decoding point, so it blocks until every
          # in-flight transaction finishes — minutes, on a busy database.
          # That would block this child's `start_link`, hence the instance
          # supervisor, hence `Bier.start_link/1` and the host application's
          # whole boot. The WAL feed is strictly additive; it must never be
          # able to hold the API's boot hostage. Connect asynchronously and
          # let the existing auto_reconnect path handle failures.
          sync_connect: false,
          name: Bier.Registry.via(conf.name, __MODULE__)
        ]
    )
  end

  @impl true
  def init(conf) do
    {:ok, %{conf: conf, registry: %{}, tx: nil, slot: nil, slot_backoff: nil, confirmed: 0}}
  end

  @impl true
  def handle_connect(state) do
    # A real (re)connect: start the slot-creation backoff over.
    create_slot(%{state | slot_backoff: nil})
  end

  # Minted fresh on every attempt, never in init/1: the slot is TEMPORARY
  # and tied to the connection that created it, so reusing a name minted
  # once for the whole process would collide (`42710 slot already exists`)
  # if a reconnect races the server reaping the previous connection's slot.
  #
  # Slot names are CLUSTER-global, so `phash2(name)` + a VM-local counter is
  # not enough: two nodes running the same release with the same instance
  # name against the same database hash identically and both start their
  # unique_integer sequence low, so they readily mint the same name. Random
  # bytes make the name unique across nodes; the hashed instance name is
  # kept only so an operator can grep `pg_replication_slots` back to an
  # instance.
  defp create_slot(state) do
    slot =
      "bier_#{:erlang.phash2(state.conf.name)}_" <>
        Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    {:query, "CREATE_REPLICATION_SLOT #{slot} TEMPORARY LOGICAL pgoutput NOEXPORT_SNAPSHOT",
     %{state | slot: slot}}
  end

  @impl true
  def handle_result(results, state) when is_list(results) do
    # The slot now exists, so this is a real restart rather than another
    # failed attempt at one: history restarts at the current LSN, announce
    # it. Deliberately here and NOT in `handle_connect/1` — a persistently
    # failing CREATE_REPLICATION_SLOT (`max_replication_slots` exhausted, a
    # name collision) is retried on `auto_reconnect`'s ~500ms backoff, and
    # bumping/broadcasting per ATTEMPT would push `bier:reset` at every
    # subscriber twice a second. The documented client contract answers each
    # one with a fresh bootstrapping `GET`, so that turns a slot outage into
    # a request storm. One reset per successful restart, none per failure.
    Buffer.new_generation(state.conf.name)

    for pid <- Events.table_subscribers(state.conf.name),
        do: send(pid, {:bier_wal_reset, "stream_restarted"})

    {:stream,
     "START_REPLICATION SLOT #{state.slot} LOGICAL 0/0 " <>
       "(proto_version '1', publication_names '#{state.conf.events_publication}')", [],
     %{state | slot_backoff: nil}}
  end

  # CREATE_REPLICATION_SLOT failed (e.g. max_replication_slots exhausted, or
  # a name collision).
  #
  # Deliberately NOT `{:disconnect, error}`: postgrex's `:reconnect_backoff`
  # is only armed when `Protocol.connect/1` itself fails. A disconnect after
  # a SUCCESSFUL connect routes through `reconnect_or_stop/4`, which posts an
  # immediate internal `{:connect, :reconnect}` event — so a persistently
  # failing slot creation would spin connect → CREATE → fail → connect at
  # full connection-setup rate, hundreds of times a second, exhausting
  # `max_connections` and starving the instance's own query pool. That turns
  # a misconfigured WAL feed into a REST outage.
  #
  # Instead keep the (working) connection and retry the query itself on an
  # exponential backoff. `max_replication_slots` exhausted is the most
  # likely cause and it clears on its own once a slot frees up.
  def handle_result(%Postgrex.Error{} = error, state) do
    backoff = next_backoff(state.slot_backoff)

    Logger.error(
      "Bier WAL consumer for #{inspect(state.conf.name)} failed to create its replication " <>
        "slot: #{Exception.message(error)} — retrying in #{backoff}ms"
    )

    Process.send_after(self(), :bier_wal_retry_slot, backoff)
    {:noreply, %{state | slot_backoff: backoff}}
  end

  @impl true
  def handle_info(:bier_wal_retry_slot, state), do: create_slot(state)
  def handle_info(_message, state), do: {:noreply, state}

  # 500ms doubling to a 30s ceiling, with jitter so N instances that lost
  # their slots together don't retry in lockstep.
  @initial_backoff 500
  @max_backoff 30_000
  defp next_backoff(nil), do: @initial_backoff

  defp next_backoff(previous) do
    ceiling = min(previous * 2, @max_backoff)
    ceiling - :rand.uniform(div(ceiling, 5))
  end

  @impl true
  def handle_data(<<?w, _start::64, _end::64, _clock::64, payload::binary>>, state) do
    {event, registry} = Pgoutput.decode(payload, state.registry)
    {:noreply, handle_event(event, %{state | registry: registry})}
  end

  def handle_data(<<?k, wal_end::64, _clock::64, reply>>, state) do
    messages =
      case reply do
        1 ->
          ack = ack_lsn(state, wal_end)
          [<<?r, ack::64, ack::64, ack::64, now()::64, 0>>]

        _ ->
          []
      end

    {:noreply, messages, state}
  end

  # CopyDone: Postgres ended the replication stream gracefully (e.g. the
  # slot was invalidated, or the server is shutting down). Reconnect rather
  # than idling on a connection that will never stream again.
  def handle_data(:done, state) do
    Logger.warning(
      "Bier WAL consumer for #{inspect(state.conf.name)} lost its replication stream " <>
        "(CopyDone); reconnecting"
    )

    {:disconnect, "replication stream ended (CopyDone)"}
  end

  # Any other frame (future protocol additions, or a bug upstream) — log and
  # keep the connection alive rather than crashing the process. Only the
  # frame's tag and size are logged, never its bytes: an unrecognised frame
  # can still carry row data, and this is the one place that would put it in
  # an operator's log file.
  def handle_data(other, state) do
    Logger.warning(
      "Bier WAL consumer for #{inspect(state.conf.name)} received an unexpected " <>
        "replication frame: #{describe_frame(other)}"
    )

    {:noreply, state}
  end

  defp describe_frame(<<tag, rest::binary>>),
    do: "tag #{inspect(<<tag>>)}, #{byte_size(rest) + 1} bytes"

  defp describe_frame(other) when is_binary(other), do: "empty frame"
  defp describe_frame(other), do: inspect(other)

  defp handle_event(%{kind: :begin}, state),
    do: %{state | tx: %{events: [], count: 0, bytes: 0, overflow: false, tables: MapSet.new()}}

  defp handle_event(
         %{kind: :commit, lsn: lsn, end_lsn: end_lsn, commit_at: commit_at},
         %{tx: tx} = state
       )
       when tx != nil do
    deliver(state, tx, lsn, commit_at)
    %{state | tx: nil, confirmed: raw_lsn(end_lsn)}
  end

  defp handle_event(%{kind: kind} = event, %{tx: tx} = state)
       when kind in [:insert, :update, :delete, :truncate] and tx != nil do
    tables = event_tables(event)
    weight = length(tables)
    bytes = event_bytes(event)
    tx = %{tx | tables: Enum.reduce(tables, tx.tables, &MapSet.put(&2, &1))}

    cond do
      tx.overflow ->
        %{state | tx: tx}

      # `events_max_tx_events` bounds the COUNT, but a transaction can blow
      # the process heap long before it trips: 9_999 updates to a table with
      # a 1MB text column is ~10GB accumulated under a 10_000-event cap. Cap
      # accumulated payload bytes too, and trip the same announced
      # `transaction_too_large` degradation on either limit.
      tx.count + weight > state.conf.events_max_tx_events or
          tx.bytes + bytes > @max_tx_bytes ->
        # Drop what was accumulated: `deliver/4`'s overflow clause discards
        # it anyway, and holding it for the rest of an arbitrarily long
        # transaction is exactly the heap growth this guard exists to stop.
        %{state | tx: %{tx | overflow: true, events: [], bytes: 0}}

      true ->
        %{
          state
          | tx: %{
              tx
              | events: [event | tx.events],
                count: tx.count + weight,
                bytes: tx.bytes + bytes
            }
        }
    end
  end

  # relation/type/origin/message frames, or data outside a tx: no-op.
  defp handle_event(_event, state), do: state

  defp deliver(state, %{overflow: true, tables: tables}, _lsn, _commit_at) do
    table_keys = MapSet.to_list(tables)
    Buffer.drop(state.conf.name, table_keys)

    for table_key <- table_keys,
        do:
          Events.broadcast_table(
            state.conf.name,
            table_key,
            {:bier_wal_reset, "transaction_too_large"}
          )

    :ok
  end

  defp deliver(_state, %{events: []}, _lsn, _commit_at), do: :ok

  defp deliver(state, %{events: events}, lsn, commit_at) do
    entries =
      events
      |> Enum.reverse()
      |> Enum.flat_map(&expand(&1, commit_at))
      |> Enum.with_index()
      |> Enum.map(fn {{table_key, event}, seq} -> {{lsn, seq}, table_key, event} end)

    retain(state, entries)

    for {cursor, table_key, event} <- entries,
        do:
          Events.broadcast_table(
            state.conf.name,
            table_key,
            {:bier_wal_event, table_key, cursor, event}
          )

    :ok
  end

  # Buffering is best-effort; LIVE delivery is not. If the Buffer is
  # momentarily gone (its own supervisor restarting it), letting the
  # `GenServer.call` exit propagate would kill this process too — and a
  # consumer restart costs the whole instance's shared restart budget and
  # resets every subscriber. Announce the lost history for the affected
  # tables instead and keep streaming: resume degrades to a reset, which is
  # the contract, rather than a silent gap or an outage.
  defp retain(state, entries) do
    Buffer.append(state.conf.name, entries)
  catch
    :exit, _reason ->
      Logger.warning(
        "Bier WAL consumer for #{inspect(state.conf.name)} could not buffer a " <>
          "transaction (buffer unavailable); resume history for the affected " <>
          "tables is announced as lost"
      )

      for table_key <- entries |> Enum.map(&elem(&1, 1)) |> Enum.uniq() do
        Events.broadcast_table(
          state.conf.name,
          table_key,
          {:bier_wal_reset, "history_evicted"}
        )
      end

      :ok
  end

  # Truncate touches several relations at once; fan a copy out per table so
  # each delivered event matches Render's singular `%{kind: :truncate,
  # relation: rel}` shape and gets its own cursor sequence.
  defp expand(%{kind: :truncate, relations: relations}, commit_at) do
    for rel <- relations,
        do: {{rel.schema, rel.table}, %{kind: :truncate, relation: rel, commit_at: commit_at}}
  end

  defp expand(%{relation: rel} = event, commit_at) do
    [{{rel.schema, rel.table}, Map.put(event, :commit_at, commit_at)}]
  end

  # The table keys an accumulated event touches, for cap/overflow accounting.
  # A truncate names N relations at once and is weighed accordingly, so
  # cap/overflow accounting counts the fanned-out events, not the single
  # wire message.
  defp event_tables(%{kind: :truncate, relations: relations}),
    do: Enum.map(relations, &{&1.schema, &1.table})

  defp event_tables(%{relation: rel}), do: [{rel.schema, rel.table}]

  # What to confirm in a standby status update. Outside a transaction
  # everything up to the server's `wal_end` has been decoded and fanned out,
  # so confirming it is both safe and necessary (it is what lets the server
  # release WAL). BETWEEN Begin and Commit it is not: `wal_end` is the
  # server's end of WAL, arbitrarily ahead of the transaction bier is still
  # assembling, so confirming it would ack rows that have not been delivered.
  # Confirm the last completed transaction's end LSN instead.
  #
  # This is currently belt-and-braces — the slot is TEMPORARY, so bier never
  # resumes from it and a too-eager ack could only cost WAL retention, not
  # data. It stops being belt-and-braces the moment the planned persistent-slot
  # opt-in lands: acking undelivered WAL there is a silent gap, exactly what
  # the feature's reset contract promises never to produce.
  defp ack_lsn(%{tx: nil}, wal_end), do: wal_end + 1
  defp ack_lsn(%{confirmed: confirmed}, _wal_end), do: confirmed

  # The decoder hands LSNs back as {hi, lo}; the wire wants the 64-bit int.
  defp raw_lsn({hi, lo}), do: hi * 0x1_0000_0000 + lo

  # A cheap upper bound on an event's payload: pgoutput delivers every value
  # as text (or :unchanged_toast / nil), so summing the binaries is both
  # accurate enough for a guard and O(columns) on data already in hand.
  defp event_bytes(%{kind: :truncate}), do: 0

  defp event_bytes(event) do
    values_bytes(Map.get(event, :row)) + values_bytes(Map.get(event, :old))
  end

  defp values_bytes(nil), do: 0

  defp values_bytes(values) do
    Enum.reduce(values, 0, fn
      {_name, value}, acc when is_binary(value) -> acc + byte_size(value)
      _other, acc -> acc
    end)
  end

  @epoch DateTime.to_unix(~U[2000-01-01 00:00:00Z], :microsecond)
  defp now, do: System.os_time(:microsecond) - @epoch
end
