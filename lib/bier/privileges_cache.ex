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
  table (e.g. an instance booted without this child, or direct test calls).
  """
  @spec fetch(Bier.name(), String.t(), reference() | nil, (-> map())) :: map()
  def fetch(name, role, generation, loader) do
    case :persistent_term.get(key(name), nil) do
      nil ->
        loader.()

      tid ->
        case :ets.lookup(tid, role) do
          [{^role, ^generation, privs}] ->
            privs

          _ ->
            privs = loader.()
            :ets.insert(tid, {role, generation, privs})
            privs
        end
    end
  end

  @impl GenServer
  def init(name) do
    tid = :ets.new(__MODULE__, [:set, :public, read_concurrency: true])
    # Replaced (global-GC'd) only at instance boot / GenServer restart —
    # never per request. Like the SchemaCache entry, it is not erased when
    # the instance stops.
    :persistent_term.put(key(name), tid)
    {:ok, tid}
  end

  defp key(name), do: {Bier, :privileges_cache, name}
end
