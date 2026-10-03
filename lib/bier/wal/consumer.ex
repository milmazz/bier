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
  larger than `events_max_tx_events`, or carrying more than 64 MiB of decoded
  column values, are dropped the same announced way
  (`"transaction_too_large"`).

  A `TRUNCATE` can name several relations at once; `Bier.Wal.Render.data/3`
  renders one event per relation (`%{kind: :truncate, relation: rel}`,
  singular), so `deliver/4` fans a decoded truncate out into one event per
  member relation — each with its own cursor sequence and table key — and
  the per-transaction event cap counts every fanned-out event, not the
  single wire message.

  ## Partitioned tables

  With `publish_via_partition_root = false` (Postgres' default) pgoutput
  names the LEAF partition a row landed in, never the partitioned table a
  client queries through. So the consumer fans every change of a partition
  out to two table keys: the leaf's own (unchanged — a leaf is an ordinary
  table and subscribers to it keep getting its events) and the TOPMOST
  root's, re-labelled with the root's name so `event:` and `"table"` say
  `orders`, not `orders_2026`. Each copy gets its own cursor sequence, the
  same way a TRUNCATE's per-relation copies do, and a TRUNCATE that names
  several leaves of one root yields ONE root copy. With
  `publish_via_partition_root = true` pgoutput already names the root, and
  nothing is fanned out.

  Which root a relation belongs to is resolved with `pg_partition_root/1`
  once per Relation message — see `resolve_root/2` for where that query runs
  and why — and cached on the relation in the decoder's registry, so a
  re-sent Relation message (every new walsender session, and after any DDL
  or ATTACH/DETACH that invalidates the relation) re-resolves it.
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
          # That would block this child's `start_link`, hence
          # `Bier.Wal.Supervisor`, hence the instance supervisor, hence
          # `Bier.start_link/1` and the host application's whole boot. The
          # WAL feed is strictly additive; it must never be able to hold the
          # API's boot hostage. Connect asynchronously and
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
    # A real (re)connect: start the slot-creation backoff over, and discard
    # any transaction the previous session was midway through assembling.
    # The new session's first data message is always a Begin, which would
    # overwrite `tx` anyway — but only once a slot exists, and until then a
    # partial transaction (up to `events_max_tx_events` events, or 64 MiB of
    # values) would sit on this process's heap for the whole length of an
    # arbitrarily long backoff. Its rows can never be delivered: a temporary
    # slot restarts at the current LSN, so the transaction is never resent.
    # `registry` stays: pgoutput re-sends every Relation per walsender
    # session before any row that needs it.
    create_slot(%{state | slot_backoff: nil, tx: nil})
  end

  # The same discard, at the moment the connection is lost. `handle_connect/1`
  # only runs after a SUCCESSFUL reconnect: through a database outage
  # postgrex keeps retrying `connect` on its backoff without calling it, so
  # clearing `tx` there alone would keep the partial transaction on the heap
  # for the whole outage. The reset in `handle_connect/1` stays as cheap
  # insurance: it costs nothing and keeps a fresh session from ever starting
  # with leftover state, whatever path led to it.
  @impl true
  def handle_disconnect(state), do: {:noreply, %{state | tx: nil}}

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
    registry = resolve_root(event, registry, state.conf)
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

  # Buffering is best-effort; LIVE delivery is not. If the Buffer call
  # fails — a timeout, or the Buffer dying mid-call in the instant before
  # `Bier.Wal.Supervisor`'s `:rest_for_one` restarts this process along with
  # it — letting the `GenServer.call` exit propagate would crash this
  # process on its own account, spending the WAL supervisor's restart budget
  # and resetting every subscriber. Announce the lost history for the
  # affected tables instead and keep streaming: resume degrades to a reset,
  # which is the contract, rather than a silent gap or a crash.
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
  # relation: rel}` shape and gets its own cursor sequence. Each relation
  # routes to its partition root as well (`targets/1`), and the copies are
  # de-duplicated by table key: truncating a partitioned table names every
  # leaf, and its subscribers should hear ONE truncate of the root, not one
  # per leaf.
  defp expand(%{kind: :truncate, relations: relations}, commit_at) do
    for rel <- truncate_targets(relations),
        do: {{rel.schema, rel.table}, %{kind: :truncate, relation: rel, commit_at: commit_at}}
  end

  defp expand(%{relation: rel} = event, commit_at) do
    for target <- targets(rel),
        do:
          {{target.schema, target.table},
           %{event | relation: target} |> Map.put(:commit_at, commit_at)}
  end

  # The table keys an accumulated event touches, for cap/overflow accounting.
  # It is `expand/2`'s key list exactly, so the cap counts what will be
  # buffered and delivered — every fanned-out copy, a truncate's N relations
  # and a partition's root copy alike — not the single wire message, and an
  # overflow's reset reaches the root's subscribers too.
  defp event_tables(%{kind: :truncate, relations: relations}),
    do: relations |> truncate_targets() |> Enum.map(&{&1.schema, &1.table})

  defp event_tables(%{relation: rel}), do: rel |> targets() |> Enum.map(&{&1.schema, &1.table})

  defp truncate_targets(relations),
    do: relations |> Enum.flat_map(&targets/1) |> Enum.uniq_by(&{&1.schema, &1.table})

  # The relations a change to `rel` is delivered as. `root` is set by
  # `resolve_root/3` for any member of a partition tree:
  #
  #   * not in a tree (or never resolved): itself only;
  #   * the root itself (`publish_via_partition_root = true` reports every
  #     change this way): the root's canonical relation, in place of its
  #     own — see `canonical_root/2` for why the two must be the same term;
  #   * a partition: itself, then the root's canonical relation.
  defp targets(%{root: %{oid: oid} = root, oid: oid}), do: [root]
  defp targets(%{root: %{} = root} = rel), do: [rel, root]
  defp targets(rel), do: [rel]

  @root_sql """
  SELECT r.oid, n.nspname, r.relname
  FROM pg_class r JOIN pg_namespace n ON n.oid = r.relnamespace
  WHERE r.oid = pg_partition_root($1::oid::regclass)
  """

  # Bounded retry for the root lookup: `@root_attempts` tries, sleeping
  # `@root_backoff * attempt` ms between them, each query capped at
  # `@root_timeout`. Worst case ~20s of blocked decoding, well inside
  # `wal_sender_timeout` (60s by default), past which the server would drop
  # the replication connection for not answering keepalives.
  @root_attempts 4
  @root_backoff 100
  @root_timeout 5_000

  # Resolves, on every Relation message, the topmost partition root of the
  # relation it describes, and caches it on the registry entry as `:root`
  # (`nil` for a relation outside any partition tree). `Pgoutput.decode/2`
  # has just replaced that entry wholesale, so a re-sent Relation message
  # always re-resolves: that is the cache invalidation, and it is exactly
  # when the answer can change, since ATTACH/DETACH PARTITION invalidate the
  # partition's relcache entry and make pgoutput re-send its Relation before
  # the next change. `pg_partition_root/1` walks every level, so a leaf of a
  # sub-partitioned table maps straight to the top.
  #
  # Where it runs: in this process, synchronously, through the INSTANCE
  # POOL. The replication connection cannot run it — it is in COPY BOTH
  # streaming mode, which admits no queries — and the root has to be known
  # before the next data message, which may follow in the same TCP read, so
  # it cannot be deferred to another process without holding up decoding
  # anyway. The cost is one indexed catalog round trip per Relation message,
  # i.e. per relation per walsender session (and after DDL), never per row.
  #
  # Failure: retried a few times on a short backoff (a burst of API traffic
  # can briefly exhaust a small pool), then RAISE. Guessing "not a
  # partition" would silently withhold every change of that leaf from its
  # root's subscribers; raising restarts this process, and the restart's
  # `stream_restarted` reset tells every subscriber history was lost — the
  # feed's "announced, never silent" contract. A lookup that keeps failing
  # keeps crashing, and `Bier.Wal.Supervisor`'s restart budget then stops
  # the feed explicitly (`bier:closed` `feed_stopped`) rather than looping.
  #
  # A relation that no longer exists by the time it is looked up (dropped
  # between the change and its decoding) resolves to no root at all: there
  # is no tree left to route it to, and Postgres reports a vanished OID the
  # same way as a plain table. The same lag applies to a DETACH racing its
  # own last pre-detach changes; both windows are the replication lag.
  defp resolve_root(%{kind: :relation, relation: %{oid: oid} = rel}, registry, conf) do
    Map.put(registry, oid, Map.put(rel, :root, lookup_root(conf, rel, 1)))
  end

  defp resolve_root(_event, registry, _conf), do: registry

  defp lookup_root(conf, rel, attempt) do
    pool = Bier.Registry.via(conf.name, Postgrex)

    case Postgrex.query(pool, @root_sql, [rel.oid], timeout: @root_timeout) do
      {:ok, %{rows: []}} ->
        nil

      {:ok, %{rows: [[root_oid, schema, table]]}} ->
        canonical_root(rel, {root_oid, schema, table})

      {:error, error} ->
        retry_root(conf, rel, attempt, error)
    end
  catch
    # A pool checkout that cannot be served exits rather than returning.
    :exit, reason -> retry_root(conf, rel, attempt, reason)
  end

  defp retry_root(conf, rel, attempt, reason) when attempt < @root_attempts do
    Logger.warning(
      "Bier WAL consumer for #{inspect(conf.name)} could not resolve the partition root " <>
        "of #{rel.schema}.#{rel.table} (attempt #{attempt}): #{describe_reason(reason)}"
    )

    Process.sleep(@root_backoff * attempt)
    lookup_root(conf, rel, attempt + 1)
  end

  defp retry_root(_conf, rel, _attempt, reason) do
    raise "Bier WAL consumer could not resolve the partition root of " <>
            "#{rel.schema}.#{rel.table}: #{describe_reason(reason)}"
  end

  defp describe_reason(%{__exception__: true} = error), do: Exception.message(error)
  defp describe_reason(reason), do: inspect(reason)

  # The relation a root copy is delivered with — the SAME term whichever
  # leaf the change came from. Partitions share their root's column names
  # and types but not its attribute order (a table created standalone and
  # ATTACHed keeps its own), and their `key?` flags follow each leaf's own
  # replica identity; carrying a leaf's column list verbatim would make the
  # root's relation look different from one leaf to the next, and
  # `Bier.Wal.Buffer` invalidates a table's history whenever its relation
  # changes. So: the root's identity, and the columns reduced to what
  # `Bier.Wal.Render` reads (name and type), in a fixed order. Row values are
  # keyed by name, so the order carries no meaning.
  defp canonical_root(rel, {root_oid, schema, table}) do
    columns =
      rel.columns
      |> Enum.map(&%{name: &1.name, type_oid: &1.type_oid, type_mod: &1.type_mod})
      |> Enum.sort_by(& &1.name)

    %{oid: root_oid, schema: schema, table: table, columns: columns}
  end

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
  #
  # Note for that feature (#153): `confirmed` is 0 only until the first
  # Commit after init/1, and it is NOT reset on reconnect (postgrex keeps the
  # module state across auto_reconnect, and handle_disconnect/1 and
  # handle_connect/1 reset only `tx` and `slot_backoff` — clearing `tx`
  # means a keepalive that lands before the new session's first Begin acks
  # `wal_end`, never a stale `confirmed` from a transaction the old session
  # abandoned). So inside the first transaction of a fresh stream this acks
  # either 0 or the previous stream's last end LSN. Both are server-side
  # no-ops: walsender ignores a flush position of InvalidXLogRecPtr, and
  # LogicalConfirmReceivedLocation never moves `confirmed_flush` backwards —
  # an under-ack costs at most WAL retention until the first Commit, never
  # data (the over-ack above is the dangerous direction). For an accurate
  # `pg_stat_replication.flush_lsn`, a persistent-slot implementation should
  # still seed `confirmed` on every (re)connect from the slot's
  # `consistent_point` (CREATE_REPLICATION_SLOT) or `confirmed_flush_lsn`
  # (reuse).
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
