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

  Only ordinary tables (`relkind = 'r'`) are subscribable: views, foreign
  tables and — deliberately, in v1 — partitioned parents all fail the same
  way, since WAL routes changes per child partition, so subscribing to the
  parent would silently deliver nothing.

  The role must also be one the authenticator may actually assume. Every
  other endpoint gets that check from Postgres for free, because
  `Bier.Auth` applies the role with `set_config('role', …)` and a
  non-member fails `42501 permission denied to set role`. Nothing here ever
  switches role — the check is a catalog lookup — so `pg_has_role(…,
  'MEMBER')` has to reproduce it explicitly. Without it a JWT naming a role
  the authenticator cannot assume (a role claim sourced from a
  user-editable field, say) would be refused by `GET /orders` and accepted
  by `GET /events?table=orders`, which is the wrong way round.
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
        AND ($4 IS NULL OR pg_has_role(current_user, $4::name, 'MEMBER'))
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
    authorized = columns(pool, role, publication, tables)

    # Scanned in REQUEST order, not result order: the response names the
    # first table the client asked for that failed, and the query carries no
    # ORDER BY (the planner may return the unnest join however it likes).
    case Enum.find(tables, &(not is_map_key(authorized, &1))) do
      nil -> {:ok, authorized}
      {schema, table} -> {:error, {:events_unknown_table, schema <> "." <> table}}
    end
  end

  @doc """
  The SELECT-able columns per table, for the tables that pass every gate —
  a table that fails any of them is simply absent from the map.

  This is `check/4` without the all-or-nothing verdict, so one query can
  answer for the union of several subscribers' tables and each subscriber's
  own verdict be derived from the result. `check/4` is written in terms of
  it.
  """
  @spec columns(term(), String.t() | nil, String.t(), [table_key()]) ::
          %{table_key() => MapSet.t(String.t())}
  def columns(pool, role, publication, tables) do
    {schemas, names} = Enum.unzip(tables)

    %{rows: rows} = Postgrex.query!(pool, @sql, [publication, schemas, names, role])

    for [schema, table, true, false, selectable] <- rows,
        selectable != [],
        into: %{},
        do: {{schema, table}, MapSet.new(selectable)}
  end
end
