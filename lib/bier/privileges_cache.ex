defmodule Bier.PrivilegesCache do
  @moduledoc """
  Per-instance, per-role cache of `Bier.Introspection.privileges/3` results
  for the root OpenAPI document (`openapi-mode = follow-privileges`).

  Entries are stamped with the `%Bier.SchemaCache{}` snapshot `generation`,
  so a schema-cache reload naturally invalidates the whole cache: the first
  root request per role after a reload misses (generation mismatch),
  re-queries, and overwrites its entry. That matches PostgREST, whose
  privilege-derived document content also refreshes on schema reload rather
  than per request.

  The GenServer owns a **public** ETS table whose tid is published once via
  `:persistent_term` — cache hits are direct ETS reads, never a process
  call. Two concurrent misses for the same role both run the loader and
  insert idempotently; the loader reads live catalog state, so either
  result is valid.

  A cache fault never fails a request: a missing table (instance without a
  cache), an unreachable owner, or a table that died mid-request (owner
  crash/restart racing a stale `:persistent_term` tid) all degrade `fetch/4`
  to calling `loader` directly, without attempting to cache — mirroring
  `Bier.JwtCache`'s handling of the identical "public ETS + persistent_term
  tid" hazard. `terminate/2` erases the `:persistent_term` entry on a clean
  shutdown so a restarted owner never leaves the old tid published past that
  point; the rescue below is what covers the remaining crash→restart window.
  """

  use GenServer

  @doc false
  def start_link(%Bier.Config{name: name}) do
    GenServer.start_link(__MODULE__, name, name: Bier.Registry.via(name, __MODULE__))
  end

  @doc """
  Returns the cached privileges for `role` under snapshot `generation`,
  running `loader` (and caching its result) on a miss.

  Falls back to a plain `loader.()` call when the instance has no cache
  table (e.g. an instance booted without this child, or direct test calls),
  or when the table has died out from under a stale published tid (owner
  mid-restart) — in the latter case nothing is cached.
  """
  @spec fetch(Bier.name(), String.t(), reference() | nil, (-> map())) :: map()
  # A nil generation means the schema cache has never been loaded (a caller
  # running before the first snapshot swap): bypass the cache entirely
  # rather than risk caching an entry no later generation can ever match.
  def fetch(_name, _role, nil, loader), do: loader.()

  def fetch(name, role, generation, loader) do
    case :persistent_term.get(key(name), nil) do
      nil ->
        loader.()

      tid ->
        case table_lookup(tid, role, generation) do
          {:hit, privs} ->
            privs

          :miss ->
            privs = loader.()
            table_insert(tid, role, generation, privs)
            privs

          :table_gone ->
            # The table died mid-request (owner crashed/restarting) while a
            # stale tid was still published: behave exactly like the
            # no-table fallback above.
            loader.()
        end
    end
  end

  # Scoped to just the ETS lookup so a table that died mid-request is the
  # only thing this catches — an ArgumentError raised by loader itself
  # (called outside this function) propagates normally instead of being
  # silently swallowed and retried.
  defp table_lookup(tid, role, generation) do
    case :ets.lookup(tid, role) do
      [{^role, ^generation, privs}] -> {:hit, privs}
      _ -> :miss
    end
  rescue
    ArgumentError -> :table_gone
  end

  # Best-effort: the result is already computed and returned to the caller
  # either way — if the table died between the lookup miss above and this
  # insert (an even tighter race), just skip caching this round.
  defp table_insert(tid, role, generation, privs) do
    :ets.insert(tid, {role, generation, privs})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp key(name), do: {Bier, :privileges_cache, name}

  @impl GenServer
  def init(name) do
    # Trap exits so terminate/2 runs on supervisor shutdown and erases the
    # persistent_term entry alongside the dying table, rather than leaving a
    # stale tid published for the next fetch/4 to trip over.
    Process.flag(:trap_exit, true)
    tid = :ets.new(__MODULE__, [:set, :public, read_concurrency: true])
    :persistent_term.put(key(name), tid)
    {:ok, %{name: name, tid: tid}}
  end

  @impl GenServer
  def terminate(_reason, %{name: name}) do
    :persistent_term.erase(key(name))
  end
end
