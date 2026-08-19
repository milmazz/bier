defmodule Bier.StatementCache do
  @moduledoc false

  # Query options for Postgrex's per-connection prepared-statement cache
  # (`db_prepared_statements`, PostgREST db-prepared-statements, issue #127).
  #
  # `cache_statement:` makes Postgrex prepare the statement once per connection
  # under the given name and reuse it while the SQL text matches, skipping the
  # parse step on every repeat. The name is a SHA-1 of the SQL, so identical
  # query shapes share one server-side statement; Postgrex compares the cached
  # entry's SQL before reuse, so a hash collision can only cause a re-prepare,
  # never execute the wrong statement. DDL that invalidates a cached plan
  # surfaces once as SQLSTATE 0A000 and Postgrex drops the entry, so the next
  # request re-prepares cleanly.

  @doc """
  Query options to append to a hot-path `Postgrex.query/4` call: a
  `cache_statement:` name derived from the SQL when enabled, nothing when
  disabled.
  """
  @spec opts(boolean(), iodata()) :: keyword()
  def opts(true, sql) do
    hash = Base.encode16(:crypto.hash(:sha, sql), case: :lower)
    [cache_statement: "bier_" <> hash]
  end

  def opts(false, _sql), do: []
end
