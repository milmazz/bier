defmodule Bier.Wal.Consumer do
  @moduledoc """
  The per-instance logical-replication consumer.

  Creates a TEMPORARY pgoutput slot against the operator's publication and
  streams it, assembling each transaction and delivering it at Commit: the
  events go into `Bier.Wal.Buffer` (for `Last-Event-ID` replay) and out to
  live subscribers via `Bier.Events.Registry`. Because the slot is
  temporary, a (re)start begins at the current LSN: the Buffer generation is
  bumped and subscribers get an explicit `{:bier_wal_reset, ...}` rather
  than a silent gap. Transactions larger than `events_max_tx_events` are
  dropped the same announced way (`"transaction_too_large"`).

  A `TRUNCATE` can name several relations at once; `Bier.Wal.Render.data/3`
  renders one event per relation (`%{kind: :truncate, relation: rel}`,
  singular), so `deliver/4` fans a decoded truncate out into one event per
  member relation — each with its own cursor sequence and table key — and
  the per-transaction event cap counts every fanned-out event, not the
  single wire message.
  """

  use Postgrex.ReplicationConnection

  alias Bier.Events.Registry, as: Events
  alias Bier.Wal.{Buffer, Pgoutput}

  def start_link(%Bier.Config{} = conf) do
    {pg_opts, _} =
      Keyword.split(Bier.postgrex_opts(conf), [:hostname, :port, :database, :username, :password])

    Postgrex.ReplicationConnection.start_link(
      __MODULE__,
      conf,
      pg_opts ++ [auto_reconnect: true, name: Bier.Registry.via(conf.name, __MODULE__)]
    )
  end

  @impl true
  def init(conf) do
    {:ok,
     %{
       conf: conf,
       registry: %{},
       tx: nil,
       slot: "bier_#{:erlang.phash2(conf.name)}_#{System.unique_integer([:positive])}"
     }}
  end

  @impl true
  def handle_connect(state) do
    # A (re)connect means history restarts at the current LSN: announce it.
    Buffer.new_generation(state.conf.name)

    for pid <- Events.table_subscribers(state.conf.name),
        do: send(pid, {:bier_wal_reset, "stream_restarted"})

    {:query, "CREATE_REPLICATION_SLOT #{state.slot} TEMPORARY LOGICAL pgoutput NOEXPORT_SNAPSHOT",
     state}
  end

  @impl true
  def handle_result(results, state) when is_list(results) do
    {:stream,
     "START_REPLICATION SLOT #{state.slot} LOGICAL 0/0 " <>
       "(proto_version '1', publication_names '#{state.conf.events_publication}')", [], state}
  end

  @impl true
  def handle_data(<<?w, _start::64, _end::64, _clock::64, payload::binary>>, state) do
    {event, registry} = Pgoutput.decode(payload, state.registry)
    {:noreply, handle_event(event, %{state | registry: registry})}
  end

  def handle_data(<<?k, wal_end::64, _clock::64, reply>>, state) do
    messages =
      case reply do
        1 -> [<<?r, wal_end + 1::64, wal_end + 1::64, wal_end + 1::64, now()::64, 0>>]
        0 -> []
      end

    {:noreply, messages, state}
  end

  defp handle_event(%{kind: :begin}, state),
    do: %{state | tx: %{events: [], count: 0, overflow: false, tables: MapSet.new()}}

  defp handle_event(%{kind: :commit, lsn: lsn, commit_at: commit_at}, %{tx: tx} = state)
       when tx != nil do
    deliver(state, tx, lsn, commit_at)
    %{state | tx: nil}
  end

  defp handle_event(%{kind: kind} = event, %{tx: tx} = state)
       when kind in [:insert, :update, :delete, :truncate] and tx != nil do
    tables = event_tables(event)
    weight = length(tables)
    tx = %{tx | tables: Enum.reduce(tables, tx.tables, &MapSet.put(&2, &1))}

    cond do
      tx.overflow ->
        %{state | tx: tx}

      tx.count + weight > state.conf.events_max_tx_events ->
        %{state | tx: %{tx | overflow: true}}

      true ->
        %{state | tx: %{tx | events: [event | tx.events], count: tx.count + weight}}
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

    Buffer.append(state.conf.name, entries)

    for {cursor, table_key, event} <- entries,
        do:
          Events.broadcast_table(
            state.conf.name,
            table_key,
            {:bier_wal_event, table_key, cursor, event}
          )

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

  @epoch DateTime.to_unix(~U[2000-01-01 00:00:00Z], :microsecond)
  defp now, do: System.os_time(:microsecond) - @epoch
end
