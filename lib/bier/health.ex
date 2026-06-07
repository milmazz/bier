defmodule Bier.Health do
  @moduledoc """
  Health checks backing the per-instance admin endpoints.

  `ready?/1` reports whether a named `Bier` instance can serve requests: its
  schema cache must be populated AND its Postgrex pool must answer a trivial
  query. The schema-cache check runs first and short-circuits, so a name with no
  cache returns `false` without touching (a possibly absent) connection pool.
  """

  alias Bier.Registry

  @doc """
  Returns `true` when the instance `name` is ready to serve requests:
  the schema cache is populated and the database answers `SELECT 1`.
  """
  @spec ready?(Bier.name()) :: boolean()
  def ready?(name) do
    schema_cache_populated?(name) and database_responsive?(name)
  end

  defp schema_cache_populated?(name) do
    map_size(:persistent_term.get({Bier, :relations, name}, %{})) > 0
  end

  defp database_responsive?(name) do
    case Postgrex.query(Registry.via(name, Postgrex), "SELECT 1", []) do
      {:ok, _result} -> true
      {:error, _reason} -> false
    end
  rescue
    DBConnection.ConnectionError -> false
    Postgrex.Error -> false
  catch
    :exit, _ -> false
  end
end
