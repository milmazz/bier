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
