defmodule Bier.Wal.Buffer do
  @moduledoc """
  Per-instance bounded history for the WAL change feed.

  One GenServer per instance owns a private `:ordered_set` ETS table keyed
  `{table_key, cursor}` — the natural key order IS replay order. Each table
  retains at most `events_buffer_size` events; a **generation** counter
  (bumped by the consumer on every (re)start) invalidates history wholesale,
  which is what turns a bier restart into an explicit `bier:reset` instead
  of a silent gap.

  Each generation also carries an **epoch floor**: the very first cursor
  appended since the bump, `:unanchored` until then. It is the floor that
  actually catches a client resuming across a restart — the endpoint reads
  the current generation straight out of this Buffer and hands it back to
  `replay_after/4`, so the generation guard only ever fires for a caller
  that remembered an older one. Any cursor below the floor (and, while
  unanchored, every cursor, since no ids have been issued yet) names
  history this generation never had: `:reset`, never a quiet resume from
  post-restart events only.
  """

  use GenServer

  alias Bier.Registry
  alias Bier.Wal.Cursor

  # Sorts before any real cursor: {{hi, lo}, seq} with lo == 0 and seq == -1.
  @floor_seq -1

  def start_link(%Bier.Config{} = conf) do
    GenServer.start_link(__MODULE__, conf, name: Registry.via(conf.name, __MODULE__))
  end

  def new_generation(name), do: GenServer.call(Registry.via(name, __MODULE__), :new_generation)
  def generation(name), do: GenServer.call(Registry.via(name, __MODULE__), :generation)

  def append(name, entries),
    do: GenServer.call(Registry.via(name, __MODULE__), {:append, entries})

  def drop(name, tables), do: GenServer.call(Registry.via(name, __MODULE__), {:drop, tables})

  @doc """
  History strictly after `cursor` for `tables`, or `:reset` when it cannot
  be served in full.

  The ETS table is `:protected`, so the traversal deliberately runs in the
  CALLING process rather than inside the server. Replay is the one
  unbounded piece of work here — up to `tables × events_buffer_size`
  entries collected, sorted and copied — and the consumer's `append/2` is a
  `GenServer.call` from inside the `Postgrex.ReplicationConnection`
  process. Serving replays from the server would put those appends behind
  them: a reconnect burst (a proxy blip, say) could exceed the call's 5s
  timeout, which raises inside the replication process, kills the consumer,
  and turns a transient reconnect into a global `stream_restarted` reset
  for every subscriber. The server keeps only the O(tables) reset decision.
  """
  def replay_after(name, tables, cursor, generation) do
    server = Registry.via(name, __MODULE__)
    plan = {:replay_plan, tables, cursor, generation}

    with {:ok, tid} <- GenServer.call(server, plan) do
      replayed =
        tables
        |> Enum.flat_map(&collect_after(tid, &1, cursor))
        |> Enum.sort_by(fn {c, _t, _e} -> c end)

      # Re-run the decision after the traversal. Because it ran outside the
      # server, a concurrent generation bump or ring eviction could have
      # removed entries this reader had not reached yet — a silent gap,
      # which is the one outcome the feed promises never to produce. Any
      # eviction that took an entry we owed the caller necessarily raises
      # that table's `oldest` above `cursor`, so re-checking catches it and
      # degrades to the same announced reset as every other lost-history
      # path.
      case GenServer.call(server, plan) do
        {:ok, _tid} -> {:ok, replayed}
        :reset -> :reset
      end
    end
  end

  @impl true
  def init(conf) do
    # `:protected` (not `:private`): only this process ever writes, but
    # `replay_after/4` reads from the subscriber's own process — see its
    # docstring for why that traversal must not run in here.
    tid = :ets.new(__MODULE__, [:ordered_set, :protected, read_concurrency: true])

    {:ok,
     %{
       tid: tid,
       limit: conf.events_buffer_size,
       generation: 0,
       floor: :unanchored,
       counts: %{},
       oldest: %{}
     }}
  end

  @impl true
  def handle_call(:new_generation, _from, state) do
    :ets.delete_all_objects(state.tid)
    generation = state.generation + 1

    {:reply, generation,
     %{state | generation: generation, floor: :unanchored, counts: %{}, oldest: %{}}}
  end

  def handle_call(:generation, _from, state), do: {:reply, state.generation, state}

  def handle_call({:append, entries}, _from, state) do
    state =
      Enum.reduce(entries, state, fn {cursor, table_key, event}, acc ->
        :ets.insert(acc.tid, {{table_key, cursor}, event})
        counts = Map.update(acc.counts, table_key, 1, &(&1 + 1))
        oldest = restore_oldest(acc.oldest, table_key, cursor)

        evict(
          %{acc | counts: counts, oldest: oldest, floor: anchor(acc.floor, cursor)},
          table_key
        )
      end)

    {:reply, :ok, state}
  end

  def handle_call({:drop, tables}, _from, state) do
    state =
      Enum.reduce(tables, state, fn table_key, acc ->
        :ets.match_delete(acc.tid, {{table_key, :_}, :_})

        %{
          acc
          | counts: Map.delete(acc.counts, table_key),
            oldest: Map.put(acc.oldest, table_key, :wrapped)
        }
      end)

    {:reply, :ok, state}
  end

  def handle_call({:replay_plan, tables, cursor, generation}, _from, state) do
    if generation != state.generation or before_floor?(state, cursor) or
         Enum.any?(tables, &stale?(state, &1, cursor)) do
      {:reply, :reset, state}
    else
      {:reply, {:ok, state.tid}, state}
    end
  end

  # The epoch floor, checked before any per-table history: the earliest
  # cursor this generation ever issued. `:unanchored` means it has issued
  # none at all yet, so every cursor a client can present was minted before
  # it — a pre-restart cursor by construction. Once anchored, anything
  # strictly below the floor is equally from a previous epoch. Both are the
  # spec's reset contract, not a gap: the per-table `oldest` map cannot see
  # this on its own, because a bump clears it and a never-touched table
  # reads as `nil` ("nothing to compare against").
  defp before_floor?(%{floor: :unanchored}, _cursor), do: true
  defp before_floor?(%{floor: floor}, cursor), do: Cursor.compare(cursor, floor) == :lt

  # The first cursor appended after a generation bump anchors that epoch's
  # floor; every later append leaves it alone.
  defp anchor(:unanchored, cursor), do: cursor
  defp anchor(floor, _cursor), do: floor

  # A table forces a reset once it has lost history — via `drop/2` or via
  # ring-buffer eviction — AND the caller's cursor doesn't cover what's
  # left. `:wrapped` means history was lost and nothing has been retained
  # since (a fully-dropped table with no new entries yet): any cursor
  # resets it. A real cursor is the earliest currently-retained entry:
  # resets only for cursors strictly older than it. A table with no
  # recorded `oldest` at all — never touched, never evicted, never dropped
  # — never forces one: there is nothing to compare the cursor against.
  defp stale?(state, table_key, cursor) do
    case Map.get(state.oldest, table_key) do
      nil -> false
      :wrapped -> true
      oldest -> Cursor.compare(cursor, oldest) == :lt
    end
  end

  # Once a table comes back from having lost all its history (`:wrapped`),
  # the next entry appended to it becomes the new floor: the earliest
  # retained cursor a caller must be at-or-past to avoid a reset. Entries
  # within one `append/2` batch arrive in cursor order, so only the first
  # one lands here — later ones see the real cursor already in place and
  # leave it alone.
  defp restore_oldest(oldest, table_key, cursor) do
    case Map.get(oldest, table_key) do
      :wrapped -> Map.put(oldest, table_key, cursor)
      _ -> oldest
    end
  end

  # Walk the ordered_set from just past {table_key, cursor}.
  defp collect_after(tid, table_key, cursor) do
    tid
    |> stream_from(:ets.next(tid, {table_key, cursor}))
    |> Enum.take_while(fn {{t, _c}, _e} -> t == table_key end)
    |> Enum.map(fn {{t, c}, e} -> {c, t, e} end)
  end

  defp stream_from(tid, start_key) do
    Stream.unfold(start_key, fn
      :"$end_of_table" ->
        nil

      key ->
        case :ets.lookup(tid, key) do
          [entry] -> {entry, :ets.next(tid, key)}
          [] -> nil
        end
    end)
  end

  # Drop the single oldest {table_key, cursor} entry once a table's count
  # exceeds the limit, and record the next survivor's cursor as the new
  # floor for that table. `events_buffer_size` is a pos_integer(), and a
  # single append only ever pushes a table one entry past its limit, so a
  # survivor always exists in practice — the `:wrapped` fallback below is
  # defensive, matching what `drop/2` records when nothing is retained.
  defp evict(state, table_key) do
    if Map.get(state.counts, table_key, 0) > state.limit do
      floor_key = {table_key, {{0, 0}, @floor_seq}}
      {^table_key, _cursor} = oldest_key = :ets.next(state.tid, floor_key)
      :ets.delete(state.tid, oldest_key)

      new_oldest =
        case :ets.next(state.tid, oldest_key) do
          {^table_key, cursor} -> cursor
          _ -> :wrapped
        end

      %{
        state
        | counts: Map.update!(state.counts, table_key, &(&1 - 1)),
          oldest: Map.put(state.oldest, table_key, new_oldest)
      }
    else
      state
    end
  end
end
