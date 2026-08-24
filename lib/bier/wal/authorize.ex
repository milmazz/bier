defmodule Bier.Wal.Authorize do
  @moduledoc """
  Subscribe-time authorization for WAL table subscriptions.

  One round trip answers, for every requested table: is it in the
  publication, is RLS enabled, and which columns can the role SELECT. A
  table fails when it is missing from the publication, has RLS enabled (v1
  refuses rather than leaks — per-event RLS is future work), or leaves the
  role zero visible columns. All failures share ONE error shape so the
  endpoint cannot be used as an existence oracle (the #81 lesson): callers
  can't distinguish "doesn't exist" from "exists but you can't see it".
  """

  @type table_key :: {String.t(), String.t()}

  @sql """
  SELECT t.schema, t.table,
         (pt.pubname IS NOT NULL) AS published,
         COALESCE(c.relrowsecurity, false) AS rls,
         COALESCE(cols.names, '{}') AS selectable
  FROM unnest($2::text[], $3::text[]) AS t("schema", "table")
  LEFT JOIN pg_class c
         ON c.relname = t."table"
        AND c.relnamespace = to_regnamespace(quote_ident(t."schema"))
        AND c.relkind = 'r'
  LEFT JOIN pg_publication_tables pt
         ON pt.pubname = $1 AND pt.schemaname = t."schema" AND pt.tablename = t."table"
  LEFT JOIN LATERAL (
    SELECT array_agg(a.attname ORDER BY a.attnum) AS names
    FROM pg_attribute a
    WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
      AND has_column_privilege(COALESCE($4, current_user), c.oid, a.attname, 'SELECT')
  ) cols ON c.oid IS NOT NULL
  """

  @doc """
  Checks whether `role` may subscribe to `tables` (each a `{schema, table}`
  pair) via `publication`. `role: nil` means "the connection's own user" —
  the semantics the API already has when auth is not applicable.

  Returns `{:ok, %{table_key => MapSet.t(colname)}}` only when every
  requested table is published, has RLS disabled, and leaves the role at
  least one SELECT-able column. Otherwise returns
  `{:error, {:events_unknown_table, "schema.table"}}` naming one offending
  table — the same shape regardless of which gate failed.
  """
  @spec check(term(), String.t() | nil, String.t(), [table_key()]) ::
          {:ok, %{table_key() => MapSet.t(String.t())}}
          | {:error, {:events_unknown_table, String.t()}}
  def check(pool, role, publication, tables) do
    {schemas, names} = Enum.unzip(tables)

    %{rows: rows} = Postgrex.query!(pool, @sql, [publication, schemas, names, role])

    Enum.reduce_while(rows, {:ok, %{}}, fn
      [schema, table, true, false, selectable], {:ok, acc} when selectable != [] ->
        {:cont, {:ok, Map.put(acc, {schema, table}, MapSet.new(selectable))}}

      [schema, table, _published, _rls, _selectable], _acc ->
        {:halt, {:error, {:events_unknown_table, schema <> "." <> table}}}
    end)
  end
end
