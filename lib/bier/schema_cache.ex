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

  alias Bier.Registry

  defstruct relations: %{},
            functions: %{},
            media_handlers: [],
            schema_comment: nil,
            postgis: false

  @type t :: %__MODULE__{
          relations: map(),
          functions: map(),
          media_handlers: list(),
          schema_comment: String.t() | nil,
          postgis: boolean()
        }

  @doc """
  Runs the full DB introspection for `schemas` against `conn`, atomically
  swaps the snapshot for `name` (see `put/2`), and returns it.

  Wrapped in the `[:bier, :schema_cache, :load, *]` telemetry span with
  metadata `%{instance: name, schemas: schemas}`; the `put/2` swap runs
  *inside* the span, before the `:stop` event fires, so a caller
  synchronizing on that event (e.g. `Bier.SchemaCacheListener`, or a test
  using `:telemetry_test`) is guaranteed the new snapshot is already visible
  by the time it observes `:stop`. A failing introspection raises and
  surfaces as the span's `:exception` event — nothing is swapped in that
  case, since `put/2` only runs after `introspect/2` succeeds.
  """
  @spec load!(Bier.name(), term(), [String.t(), ...]) :: t()
  def load!(name, conn, schemas) do
    Bier.Telemetry.schema_cache_load(%{instance: name, schemas: schemas}, fn ->
      cache = introspect(conn, schemas)
      put(name, cache)
      {cache, %{relation_count: map_size(cache.relations)}}
    end)
  end

  defp introspect(conn, schemas) do
    %__MODULE__{
      relations: Bier.Introspection.run(conn, schemas),
      functions: Bier.Introspection.functions(conn, schemas),
      media_handlers: Bier.Introspection.media_handlers(conn, schemas),
      schema_comment: Bier.Introspection.schema_comment(conn, hd(schemas)),
      postgis: Bier.Introspection.postgis?(conn)
    }
  end

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

  @doc "Whether the postgis extension is installed (gates the geo+json producer)."
  @spec postgis?(Bier.name()) :: boolean()
  def postgis?(name), do: get(name).postgis

  @doc "Whether a non-empty snapshot has been loaded for `name`."
  @spec loaded?(Bier.name()) :: boolean()
  def loaded?(name), do: map_size(relations(name)) > 0

  @doc """
  Re-runs the database introspection for the **running** instance `name` and
  atomically swaps its snapshot — the programmatic equivalent of PostgREST's
  `NOTIFY pgrst, 'reload schema'`.

  Resolves the instance's config and connection pool from `Bier.Registry`, so
  it works whether or not the LISTEN/NOTIFY listener (`db_channel_enabled`)
  is running. The swap happens only after a fully successful introspection:
  on any failure the previous snapshot stays in place and `{:error, reason}`
  is returned. An unregistered `name` returns `{:error, :unknown_instance}`.

  Delegates to `load!/3`, which swaps the snapshot inside the
  `[:bier, :schema_cache, :load, *]` telemetry span, before the `:stop` event
  fires — so a caller synchronizing on that event (e.g.
  `Bier.SchemaCacheListener`, or a test using `:telemetry_test`) is guaranteed
  the new snapshot is already visible by the time it observes `:stop`.
  """
  @spec reload(Bier.name()) :: :ok | {:error, term()}
  def reload(name) do
    case Registry.whereis(name) do
      nil ->
        {:error, :unknown_instance}

      _pid ->
        config = Registry.config(name)
        conn = Registry.via(name, Postgrex)

        load!(name, conn, config.db_schemas)

        :ok
    end
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, reason}
  end

  defp key(name), do: {Bier, :schema_cache, name}
end
