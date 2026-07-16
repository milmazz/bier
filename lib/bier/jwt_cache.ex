defmodule Bier.JwtCache do
  @moduledoc """
  Per-instance JWT verification-result cache (PostgREST jwt-cache-max-entries).

  Caches only the expensive half of verification — `Bier.JWT.decode_and_verify/2`
  (signature check + claims decode) — keyed by the raw bearer token. Temporal
  and audience validation run on every request *after* the lookup
  (`Bier.JWT.validate_claims/3` in `Bier.Auth`), so a cached token still
  starts failing the moment its `exp` passes; the cache itself never
  invalidates on time, mirroring PostgREST v14.12's `Auth.JwtCache`. Failed
  verifications are never inserted.

  ## Layout

  The GenServer owns one public ETS set whose handle lives in
  `:persistent_term` under `{Bier, :jwt_cache, name}`. Request processes read
  and set the SIEVE visited bit directly (lock-free hits); inserts and
  evictions are serialized through the owner. Rows are
  `{token, claims, claims_json, visited?}`.

  ## Eviction: SIEVE

  Insertion order is kept in the owner's state as a doubly-linked map
  (`token => {newer, older}` plus `head`/`tail`/`hand` pointers). At capacity
  the hand walks from the oldest entry toward newer ones, clearing visited
  bits on survivors; the first unvisited entry is evicted (emitting
  `[:bier, :jwt_cache, :eviction]`) and the hand parks at the next newer
  entry, wrapping to the tail when it walks past the head.

  A cache fault never fails a request: a missing table (instance without a
  cache, or the owner mid-restart) or an unreachable owner degrades `fetch/3`
  to calling `verify_fun` directly.
  """

  use GenServer

  def start_link(%Bier.Config{name: name} = conf) do
    GenServer.start_link(__MODULE__, conf, name: Bier.Registry.via(name, __MODULE__))
  end

  @doc "True when this config runs the cache: a secret and a positive max."
  @spec enabled?(Bier.Config.t()) :: boolean()
  def enabled?(%Bier.Config{jwt_secret: secret, jwt_cache_max_entries: max}),
    do: is_binary(secret) and max > 0

  @doc """
  Look `token` up in `name`'s cache, calling `verify_fun` on a miss and
  inserting its successful result. Emits `[:bier, :jwt_cache, :lookup]` per
  consultation. Without a running cache, delegates straight to `verify_fun`
  (no events — PostgREST records no observations in no-cache mode).
  """
  @spec fetch(atom(), String.t(), (-> {:ok, map(), String.t()} | {:error, term()})) ::
          {:ok, map(), String.t()} | {:error, term()}
  def fetch(name, token, verify_fun) do
    case :persistent_term.get(key(name), nil) do
      nil -> verify_fun.()
      tid -> lookup(tid, name, token, verify_fun)
    end
  end

  defp lookup(tid, name, token, verify_fun) do
    case table_lookup(tid, token) do
      {:hit, claims, claims_json} ->
        Bier.Telemetry.jwt_cache_lookup(true, %{instance: name})
        {:ok, claims, claims_json}

      :miss ->
        Bier.Telemetry.jwt_cache_lookup(false, %{instance: name})

        with {:ok, claims, claims_json} <- verify_fun.() do
          insert(name, token, claims, claims_json)
          {:ok, claims, claims_json}
        end

      :table_gone ->
        # The table died mid-request (owner restarting): verify directly.
        verify_fun.()
    end
  end

  # Scoped to just the two :ets calls so a table that died mid-request is the
  # only thing this catches — an ArgumentError raised by verify_fun itself
  # (called outside this function) propagates normally instead of triggering
  # a second, silent invocation.
  defp table_lookup(tid, token) do
    case :ets.lookup(tid, token) do
      [{^token, claims, claims_json, _visited}] ->
        :ets.update_element(tid, token, {4, true})
        {:hit, claims, claims_json}

      [] ->
        :miss
    end
  rescue
    ArgumentError -> :table_gone
  end

  # The result is already verified — if the owner is down or slow, skip
  # caching rather than fail or block the request.
  defp insert(name, token, claims, claims_json) do
    GenServer.call(Bier.Registry.via(name, __MODULE__), {:insert, token, claims, claims_json})
  catch
    :exit, _reason -> :ok
  end

  defp key(name), do: {Bier, :jwt_cache, name}

  ## GenServer (owner: table lifecycle + serialized structural writes)

  @impl GenServer
  def init(%Bier.Config{name: name, jwt_cache_max_entries: max}) do
    # Trap exits so terminate/2 runs on supervisor shutdown and erases the
    # persistent_term entry alongside the dying table.
    Process.flag(:trap_exit, true)
    tid = :ets.new(__MODULE__, [:set, :public, read_concurrency: true])
    :persistent_term.put(key(name), tid)

    {:ok,
     %{name: name, tid: tid, max: max, count: 0, order: %{}, head: nil, tail: nil, hand: nil}}
  end

  @impl GenServer
  def handle_call({:insert, token, claims, claims_json}, _from, state) do
    if Map.has_key?(state.order, token) do
      # Two requests raced the same miss; first insert wins.
      {:reply, :ok, state}
    else
      state = if state.count >= state.max, do: evict(state), else: state
      :ets.insert(state.tid, {token, claims, claims_json, false})
      {:reply, :ok, push_head(state, token)}
    end
  end

  @impl GenServer
  def terminate(_reason, state) do
    :persistent_term.erase(key(state.name))
  end

  ## SIEVE
  #
  # order: token => {newer, older}; head is the newest entry, tail the oldest.
  # Only this process mutates order/ETS membership, so every token in order is
  # present in ETS by construction.

  defp evict(%{hand: hand, tail: tail} = state), do: sweep(state, hand || tail)

  # Walked past the head: wrap to the tail. Termination: every visited entry
  # passed gets its bit cleared, so a second pass over any entry evicts it.
  defp sweep(state, nil), do: sweep(state, state.tail)

  defp sweep(state, token) do
    {newer, _older} = Map.fetch!(state.order, token)

    if :ets.lookup_element(state.tid, token, 4) do
      :ets.update_element(state.tid, token, {4, false})
      sweep(state, newer)
    else
      :ets.delete(state.tid, token)
      Bier.Telemetry.jwt_cache_eviction(%{instance: state.name})
      state |> unlink(token) |> Map.put(:hand, newer)
    end
  end

  defp push_head(%{head: nil} = state, token) do
    %{state | order: %{token => {nil, nil}}, head: token, tail: token, count: 1}
  end

  defp push_head(%{head: head} = state, token) do
    order =
      state.order
      |> Map.update!(head, fn {_newer, older} -> {token, older} end)
      |> Map.put(token, {nil, head})

    %{state | order: order, head: token, count: state.count + 1}
  end

  defp unlink(state, token) do
    {{newer, older}, order} = Map.pop!(state.order, token)

    order =
      order
      |> relink(newer, fn {n, _o} -> {n, older} end)
      |> relink(older, fn {_n, o} -> {newer, o} end)

    %{
      state
      | order: order,
        head: if(state.head == token, do: older, else: state.head),
        tail: if(state.tail == token, do: newer, else: state.tail),
        count: state.count - 1
    }
  end

  defp relink(order, nil, _fun), do: order
  defp relink(order, neighbor, fun), do: Map.update!(order, neighbor, fun)
end
