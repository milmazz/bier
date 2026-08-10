defmodule Bier.Embed do
  @moduledoc """
  Resource embedding (PostgREST `select=...,rel(...)`) for the read pipeline.

  Given the parsed select tree, the source `Relation`, its SQL alias, and the
  full introspection map, this module produces:

    * `build_row_select/6` — the named select list (`{expr, out_name}` pairs)
      for a derived table whose row record the executor aggregates with
      `json_agg`. Scalar fields, json-paths, casts, aggregates, computed
      columns, embeds (many-to-one / one-to-many / many-to-many / one-to-one /
      spread / computed relationships) are rendered here as correlated
      sub-queries or, for spread, pulled up through a `LEFT JOIN LATERAL`.
    * `inner_join_where/6` — the extra `WHERE` predicate that an `!inner` embed
      (or an embedded filter that implies inner) adds to the *source* query so
      rows whose embedding is empty are dropped.
    * `group_by/3` — the implicit `GROUP BY` clause when plain fields are mixed
      with aggregates.

  Relationship resolution walks the foreign keys discovered by
  `Bier.Introspection`, plus computed relationships (SETOF-returning functions).
  Disambiguation errors (`PGRST200` / `PGRST201`) are thrown as
  `{:embed_error, body}` and turned into responses by the controller.
  """

  alias Bier.Introspection.Relation
  alias Bier.QueryExecutor, as: QE

  # The plan keys whose map is keyed by an embed path.
  @embed_path_keys [:embed_filters, :embed_orders, :embed_limits, :embed_offsets]

  @doc """
  Resolve the embed *target names* a request's filters, orders, limits and
  offsets used, rewriting each path to the embed's canonical name.

  PostgREST resolves `<target>.<...>` query params against the select tree with
  `matchTarget`, which under `url-use-legacy-target-names = true` accepts either
  the embed's alias or its relation name, and binds the param to the **first**
  matching node (`Plan.hs` `updateNode … find`). Both spellings are normalised
  here to `alias || relation`, the key the SQL builder routes on, so that:

    * an aliased embed still answers to its relation name (`tasks.name` for
      `the_tasks:tasks(...)`), and
    * embedding the same relation twice keeps the two filters apart — the plain
      node claims `tasks.` before the aliased node can (v16.0's "unexpected
      results when embedding and filtering the same table more than once" fix).

  Every legacy match is recorded in the plan's `:legacy_target_names` as a
  `{relation_name, alias}` pair (`relIsLegacyTargetNameMatch`), which
  `Bier.Plugs.Warning` turns into the deprecation `Warning` header.

  A target name that resolves to no node is a 400 PGRST108 (`updateNode`'s
  `NotEmbedded`), returned as `{:error, {:embed_not_selected, name}}` — or, when
  the name would have resolved under the legacy rule (i.e. it is the relation
  name of an *aliased* embed and `legacy?` is false),
  `{:error, {:embed_not_selected, name, alias}}`, which carries the
  alias-specific `details`/`hint` PostgREST builds from `findLegacyUsage`.
  """
  @spec resolve_target_names(map(), boolean()) ::
          {:ok, map()}
          | {:error,
             {:embed_not_selected, String.t()} | {:embed_not_selected, String.t(), String.t()}}
  def resolve_target_names(plan, legacy? \\ true) when is_map(plan) do
    paths =
      @embed_path_keys
      |> Enum.flat_map(&Map.keys(Map.get(plan, &1) || %{}))
      |> Enum.uniq()

    {rewrites, legacy} = resolve_level(Map.get(plan, :select), paths, legacy?)

    plan =
      @embed_path_keys
      |> Enum.reduce(plan, fn key, acc ->
        case Map.get(acc, key) do
          nil -> acc
          map -> Map.put(acc, key, rekey(map, rewrites))
        end
      end)
      |> Map.put(:legacy_target_names, Enum.uniq(legacy))

    {:ok, plan}
  catch
    {:not_embedded, reason} -> {:error, reason}
  end

  defp rekey(map, rewrites) do
    Map.new(map, fn {path, value} -> {Map.get(rewrites, path, path), value} end)
  end

  # Resolve one level of the select tree: group the paths by their head, hand
  # each group to the node that owns it, then recurse with the tails.
  defp resolve_level(nodes, paths, legacy?) when is_list(nodes) and paths != [] do
    paths
    |> Enum.group_by(&hd/1)
    |> Enum.reduce({%{}, []}, fn {head, group}, {rewrites, legacy} ->
      case owner(nodes, head, legacy?) do
        :none ->
          throw({:not_embedded, not_embedded(nodes, head, legacy?)})

        {node, canonical, legacy_match?} ->
          tails = for [_ | rest] <- group, rest != [], do: rest
          {child_rewrites, child_legacy} = resolve_level(child_nodes(node), tails, legacy?)

          rewrites =
            Enum.reduce(group, rewrites, fn [_ | rest] = path, acc ->
              Map.put(acc, path, [canonical | Map.get(child_rewrites, rest, rest)])
            end)

          {rewrites, legacy ++ legacy_pair(node, legacy_match?) ++ child_legacy}
      end
    end)
  end

  defp resolve_level(_nodes, _paths, _legacy?), do: {%{}, []}

  # The first node the target name resolves to, mirroring `find` over the
  # forest: a canonical (alias, else relation) match, or — only under the legacy
  # rule — an aliased node addressed by its relation name.
  defp owner(nodes, head, legacy?) do
    Enum.find_value(nodes, :none, fn
      %{kind: :embed} = e ->
        cond do
          canonical_name(e) == head -> {e, head, false}
          legacy? and e.target == head -> {e, canonical_name(e), true}
          true -> nil
        end

      _node ->
        nil
    end)
  end

  # The PGRST108 payload for an unresolvable target name. PostgREST's
  # `findLegacyUsage` re-runs the lookup under the legacy rule *only* when the
  # legacy rule is off; a name that then resolves must be the relation name of
  # an aliased embed, so the error names the alias to use instead. With the
  # legacy rule on there is nothing else to try and the plain form is used.
  defp not_embedded(nodes, head, false) do
    case owner(nodes, head, true) do
      {%{alias: al}, _canonical, true} when is_binary(al) -> {:embed_not_selected, head, al}
      _ -> {:embed_not_selected, head}
    end
  end

  defp not_embedded(_nodes, head, _legacy?), do: {:embed_not_selected, head}

  defp canonical_name(e), do: e.alias || e.target

  defp child_nodes(%{select: select}) when is_list(select), do: select
  defp child_nodes(_node), do: []

  defp legacy_pair(%{alias: al, target: target}, true) when is_binary(al), do: [{target, al}]
  defp legacy_pair(_node, _legacy_match?), do: []

  @doc """
  Build the named select list for a single row of `relation` (aliased as `al`),
  given the select `nodes`. Returns `{cols, laterals, state}`: `cols` is a list
  of `{expr, out_name}` pairs (rendered with `render_cols/1`), `laterals` is a
  list of ` LEFT JOIN LATERAL (...) ON true` clauses contributed by spread
  embeds. Aggregating the derived table's row record (instead of a
  `json_build_object` scalar, which spaces `"k" : v`) matches PostgREST's
  wire bytes — see issue #31. `embed_filters` maps embed paths to filter
  nodes. `qe` is the executor module (passed to avoid a compile cycle).
  """
  def build_row_select(nodes, %Relation{} = relation, al, embed_filters, state, qe) do
    {entries, state} =
      Enum.flat_map_reduce(nodes, state, fn node, st ->
        build_node(node, relation, al, embed_filters, st, qe)
      end)

    Enum.reduce(entries, {[], [], state}, fn
      {:spread_cols, spread_cols, lateral}, {cols, lats, st} ->
        {cols ++ spread_cols, lats ++ [lateral], st}

      {_expr, _name} = col, {cols, lats, st} ->
        {cols ++ [col], lats, st}
    end)
  end

  @doc false
  # Render `{expr, out_name}` pairs as a SQL select list.
  def render_cols(cols) do
    Enum.map_join(cols, ", ", fn {expr, name} -> "#{expr} AS #{QE.quote_ident(name)}" end)
  end

  # ---- node dispatch -------------------------------------------------------

  defp build_node(node, relation, al, _ef, state, _qe) when node == :star do
    {star_pairs(relation, al), state}
  end

  defp build_node(%{kind: :star}, relation, al, _ef, state, _qe) do
    {star_pairs(relation, al), state}
  end

  defp build_node(%{kind: :field} = f, relation, al, _ef, state, _qe) do
    name = f.alias || QE.json_output_name(f.column, f.json_path)
    expr = field_expr(f, relation, al)
    {[{expr, name}], state}
  end

  # `AGG(<field>)::<result cast>` — PostgREST's `pgFmtApplyAggregate agg aggCast
  # (pgFmtApplyCast cast (pgFmtTableCoerce table fld))`: the aggregated operand
  # is an ordinary select field (json path, read representation and *input* cast
  # included), and only the trailing cast applies to the aggregate's result.
  defp build_node(%{kind: :agg} = a, relation, al, _ef, state, _qe) do
    inner =
      case a.column do
        nil -> "#{a.fun}(*)"
        col -> "#{a.fun}(#{field_expr(agg_operand(a, col), relation, al)})"
      end

    inner = if a.cast, do: "#{inner}::#{QE.quote_type(a.cast)}", else: inner
    name = a.alias || a.fun
    {[{inner, name}], state}
  end

  # An empty-projection embed (`rel()`) establishes the relationship for null
  # filtering but contributes no key to the output row.
  defp build_node(%{kind: :embed, empty: true}, _relation, _al, _ef, state, _qe) do
    {[], state}
  end

  defp build_node(%{kind: :embed} = e, relation, al, ef, state, qe) do
    rel = resolve_relationship(e, relation, state.relations)
    build_embed(e, rel, relation, al, ef, state, qe)
  end

  defp agg_operand(a, col),
    do: %{column: col, json_path: a.json_path, cast: a.input_cast}

  defp star_pairs(relation, al) do
    Enum.map(relation.columns, fn c ->
      {star_col_expr(relation, al, c.name), c.name}
    end)
  end

  # ---- scalar field expr ---------------------------------------------------

  defp field_expr(%{column: col} = f, relation, al) do
    base =
      if col in relation.computed_columns do
        "#{QE.quote_ident(relation.schema)}.#{QE.quote_ident(col)}(#{QE.quote_ident(al)})"
      else
        QE.column_expr_aliased(col, f.json_path, al, relation)
      end

    # Apply the column's read representation before any explicit `::cast`,
    # unless a json path navigates into the value (then the base value is used).
    base = if f.json_path == [], do: QE.apply_read_rep(base, relation, col), else: base
    if f.cast, do: "#{base}::#{QE.quote_type(f.cast)}", else: base
  end

  # Column value for a `*` expansion, applying the column's read representation.
  defp star_col_expr(relation, al, col) do
    QE.apply_read_rep(col_expr(al, col), relation, col)
  end

  # ---- embed rendering -----------------------------------------------------

  defp build_embed(e, rel, _source, src_alias, ef, state, qe) do
    %{relation: target, kind: kind, join_cond: join} = rel

    seq = state.embed_seq + 1
    state = %{state | embed_seq: seq}
    child_alias = "#{target.name}_e#{seq}"
    out_name = e.alias || rel.embed_key

    # Filter/order/limit/offset keys have already been resolved to this embed's
    # canonical name by `resolve_target_names/2` (which is where the alias vs
    # relation-name spellings are reconciled), so routing is an exact match.
    segments = [embed_segment(e, rel)]

    {own_filters, deeper_filters} = pop_embed_filters(ef, segments)

    # A filter of this embed whose column names one of ITS OWN embeds is a null
    # filter on that nested resource (`child.grandchild=not.is.null`), not a
    # column of `target`. `addNullEmbedFilters` recurses into the whole forest,
    # so the rewrite is applied at every depth (case 1194).
    own_filters = rewrite_null_embed_filters(own_filters, e.select, deeper_filters)

    {own_order, deeper_orders} = pop_embed_orders(state.embed_orders, segments)
    {own_limit, deeper_limits} = pop_embed_paged(state.embed_limits, segments)
    {own_offset, deeper_offsets} = pop_embed_paged(state.embed_offsets, segments)

    # Descend into the child scope (the embed's own relation + the embed-keyed
    # orders/limits/offsets routed deeper), then restore the parent scope —
    # only the parameter accumulator and embed sequence survive the descent.
    saved =
      Map.take(state, [:relation, :embed_orders, :embed_limits, :embed_offsets])

    child_scope = %{
      state
      | relation: target,
        embed_orders: deeper_orders,
        embed_limits: deeper_limits,
        embed_offsets: deeper_offsets
    }

    {child_cols, child_laterals, state} =
      build_row_select(e.select, target, child_alias, deeper_filters, child_scope, qe)

    # An `!inner` embedding NESTED inside this one propagates its filter up to
    # here as well: a child row whose own inner embedding is empty is dropped
    # from the array, which is what makes a two-level `!inner` chain shrink
    # every level instead of only the deepest one (case 1192).
    {nested_inner, state} =
      inner_join_clauses(e.select, target, child_alias, deeper_filters, state, qe)

    # `own_filters` target the embed's own columns (e.g. `tasks.id=gte.5`), so
    # they must render while `state.relation` is still `target` — a coltype
    # lookup against the (already-restored) parent relation would silently
    # fall back to `:text` and bind a raw string where Postgres expects the
    # column's real type (e.g. integer), causing a Postgrex encode error (#72).
    {where_sql, state} =
      build_embed_where(join, own_filters, nested_inner, child_alias, src_alias, state, qe)

    state = struct!(state, saved)

    {order_sql, state} =
      build_order_advanced(own_order, e.select, target, child_alias, state, qe)

    page_sql = paginate_sql(own_limit, own_offset)

    from = from_clause(target, child_alias, rel, src_alias)
    lateral_sql = Enum.join(child_laterals, "")
    child_select = child_select_list(child_cols)

    inner_base = "SELECT #{child_select} FROM #{from}#{lateral_sql}#{where_sql}#{order_sql}"

    if e.spread do
      spread_entry(kind, child_cols, inner_base, page_sql, state)
    else
      # Embed internals go through jsonb (to_jsonb / json_agg(to_jsonb(…))):
      # PostgREST renders embedded objects jsonb-style — `": "` spacing and
      # jsonb key normalization — while parent rows stay compact. Live-verified
      # against PostgREST 14.12 (spec §0). An all-empty child select (only
      # empty embeds, e.g. `rel(sub())`) still renders `{}` rows, as
      # json_build_object() did — the jsonb wrapper over the `_bier_empty_row`
      # placeholder column would produce `{"_bier_empty_row": {}}`, so it is
      # special-cased to a bare `'{}'::json`.
      sub =
        case {kind, child_cols} do
          {:one, []} ->
            inner = "SELECT 1 FROM #{from}#{where_sql}#{order_sql} LIMIT 1"
            "(SELECT '{}'::json FROM (#{inner}) _bier_c)"

          {:many, []} ->
            inner = "SELECT 1 FROM #{from}#{where_sql}#{order_sql}#{page_sql}"
            "COALESCE((SELECT json_agg('{}'::json) FROM (#{inner}) _bier_c), '[]'::json)"

          {:one, _cols} ->
            "(SELECT to_jsonb(_bier_c) FROM (#{inner_base} LIMIT 1) _bier_c)"

          {:many, _cols} ->
            "COALESCE((SELECT json_agg(to_jsonb(_bier_c)) " <>
              "FROM (#{inner_base}#{page_sql}) _bier_c), '[]'::json)"
        end

      {[{sub, out_name}], state}
    end
  end

  # A child select that projects no columns (e.g. every node is an empty
  # embed) still renders `{}` rows, as json_build_object() did.
  defp child_select_list([]), do: "'{}'::json AS _bier_empty_row"
  defp child_select_list(cols), do: render_cols(cols)

  # Spread merges the embedded resource's columns into the parent row.
  # PostgREST implements this by pulling the child's columns up through a
  # LEFT JOIN LATERAL, so a missing to-one row contributes NULL columns (the
  # keys stay present, value null) with no COALESCE template needed. A to-many
  # spread aggregates each child column into a JSON array under its key
  # (PostgREST v12.1 semantics).
  defp spread_entry(kind, child_cols, inner_base, page_sql, state) do
    seq = state.embed_seq + 1
    state = %{state | embed_seq: seq}
    spr = QE.quote_ident("_bier_spr#{seq}")

    lateral =
      case kind do
        :one ->
          " LEFT JOIN LATERAL (#{inner_base} LIMIT 1) #{spr} ON true"

        :many ->
          aggs =
            Enum.map_join(child_cols, ", ", fn {_expr, name} ->
              q = QE.quote_ident(name)
              "COALESCE(json_agg(_bier_s.#{q}), '[]'::json) AS #{q}"
            end)

          " LEFT JOIN LATERAL (SELECT #{aggs} FROM (#{inner_base}#{page_sql}) _bier_s) " <>
            "#{spr} ON true"
      end

    cols = Enum.map(child_cols, fn {_expr, name} -> {"#{spr}.#{QE.quote_ident(name)}", name} end)
    {[{:spread_cols, cols, lateral}], state}
  end

  defp from_clause(target, child_alias, %{via: nil, join_cond: jc}, _src) when jc != :computed do
    "#{QE.qrel(target)} #{QE.quote_ident(child_alias)}"
  end

  defp from_clause(target, child_alias, %{via: {jrel, _}}, _src) do
    jalias = child_alias <> "_j"

    "#{QE.qrel(jrel)} #{QE.quote_ident(jalias)}, #{QE.qrel(target)} #{QE.quote_ident(child_alias)}"
  end

  defp from_clause(_target, child_alias, %{computed: {fn_schema, fn_name}}, src_alias) do
    "#{QE.quote_ident(fn_schema)}.#{QE.quote_ident(fn_name)}(#{QE.quote_ident(src_alias)}) #{QE.quote_ident(child_alias)}"
  end

  # ---- embed WHERE ---------------------------------------------------------

  defp build_embed_where(join, own_filters, extra, child_alias, src_alias, state, qe) do
    join_sql = render_join(join, child_alias, src_alias)

    {filt_sql, state} = render_filters(own_filters, child_alias, state, qe)

    combined =
      ([join_sql, filt_sql] ++ extra)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" AND ")

    where = if combined == "", do: "", else: " WHERE " <> combined
    {where, state}
  end

  defp render_filters([], _alias, state, _qe), do: {"", state}

  defp render_filters(filters, alias_name, state, qe) do
    prev = state.alias_name

    {clauses, st} =
      Enum.map_reduce(filters, %{state | alias_name: alias_name}, &qe.render_node(&1, &2))

    {Enum.join(clauses, " AND "), %{st | alias_name: prev}}
  end

  # Join predicate linking child to source.
  defp render_join({:direct, pairs}, child_alias, src_alias) do
    Enum.map_join(pairs, " AND ", fn {ccol, scol} ->
      "#{col_expr(child_alias, ccol)} = #{col_expr(src_alias, scol)}"
    end)
  end

  defp render_join({:via, jpairs, tpairs}, child_alias, src_alias) do
    jalias = child_alias <> "_j"

    j =
      Enum.map(jpairs, fn {jcol, scol} ->
        "#{col_expr(jalias, jcol)} = #{col_expr(src_alias, scol)}"
      end)

    t =
      Enum.map(tpairs, fn {jcol, tcol} ->
        "#{col_expr(jalias, jcol)} = #{col_expr(child_alias, tcol)}"
      end)

    Enum.join(j ++ t, " AND ")
  end

  defp render_join(:computed, _child_alias, _src_alias), do: ""

  # ---- inner join propagation ---------------------------------------------

  @doc """
  Builds the WHERE predicate added to the *source* query for `!inner` embeds.

  The propagation is recursive: an `!inner` embed nested inside another one
  contributes its own `EXISTS` inside the outer one, so a filter N levels down
  drops non-matching rows at every level of the chain (case 1192).
  """
  def inner_join_where(nodes, %Relation{} = relation, al, embed_filters, state, qe) do
    {clauses, state} = inner_join_clauses(nodes, relation, al, embed_filters, state, qe)

    where =
      case clauses do
        [] -> ""
        list -> " WHERE " <> Enum.join(list, " AND ")
      end

    {where, state}
  end

  # The `!inner` EXISTS clauses contributed by one level of the select tree.
  # Only an explicit `!inner` propagates an embedded filter to its parent
  # (dropping parents with no matching child); the default (left) join applies
  # the filter to the embedded rows only and keeps every parent row, with an
  # empty array where nothing matches (case 1182 vs 1181).
  defp inner_join_clauses(nodes, %Relation{} = relation, al, embed_filters, state, qe) do
    Enum.flat_map_reduce(nodes, state, fn
      %{kind: :embed, join: :inner} = e, st ->
        rel = resolve_relationship(e, relation, st.relations)
        {own, deeper} = pop_embed_filters(embed_filters, [embed_segment(e, rel)])
        {sql, st2} = exists_clause(e, rel, al, own, deeper, st, qe)
        {[sql], st2}

      _other, st ->
        {[], st}
    end)
  end

  @doc """
  Rewrite every filter leaf whose column names one of `select`'s embeds into a
  null-filter on that embedded resource (`<embed>=is.null` /
  `<embed>=not.is.null`).

  This is PostgREST's `addNullEmbedFilters` (`Plan.hs` L959-L972): it recurses
  through `CoercibleExpr` before rewriting leaves, so a null filter may sit
  inside an `and=()`/`or=()` group and two embeds can be OR-ed against each
  other (case 1195); and it recurses into the whole read-plan forest, so the
  rewrite applies at every nesting depth (case 1194).

  The embed's OWN filters (`<embed>.<col>=…`, taken from `embed_filters`) are
  carried on the rewritten node because PostgREST evaluates the null test
  against the embed's *post-filter* aggregate — the embedded filter lives
  inside the embed's LEFT JOIN LATERAL and shrinks the aggregate first, so an
  embed whose rows were all filtered out aggregates to NULL (cases 1198/1199).
  """
  def rewrite_null_embed_filters(filters, select, embed_filters)
      when is_list(filters) and is_list(select) do
    Enum.map(filters, &rewrite_null_node(&1, select, embed_filters))
  end

  def rewrite_null_embed_filters(filters, _select, _embed_filters), do: filters

  defp rewrite_null_node(%{logic: _, children: children} = node, select, embed_filters) do
    %{node | children: Enum.map(children, &rewrite_null_node(&1, select, embed_filters))}
  end

  defp rewrite_null_node(%{column: col, json_path: []} = f, select, embed_filters) do
    case find_embed_node(select, col) do
      nil ->
        f

      e ->
        {own, deeper} = pop_embed_filters(embed_filters, [e.alias || e.target])

        %{
          embed_null: e,
          present?: embed_presence?(f),
          filters: rewrite_null_embed_filters(own, e.select, deeper)
        }
    end
  end

  defp rewrite_null_node(node, _select, _embed_filters), do: node

  @doc """
  Render a node produced by `rewrite_null_embed_filters/3` against the current
  scope (`state.relation` / `state.alias_name`).

  A correlated scalar `count(*)` subquery cannot be pulled up into a semi/anti
  join, so the parent scan order is preserved (matching PostgREST's
  LATERAL-based null filtering, whose row order the frozen cases pin). `> 0`
  keeps parents that HAVE a surviving related row; `= 0` keeps those with none.
  """
  def render_null_embed(%{embed_null: e, present?: present?, filters: filters}, state, qe) do
    source = state.relation
    rel = resolve_relationship(e, source, state.relations)
    %{relation: target, join_cond: join} = rel

    seq = state.embed_seq + 1
    state = %{state | embed_seq: seq}
    child_alias = "#{embed_alias(target.name, e.alias)}_n#{seq}"

    join_sql = render_join(join, child_alias, state.alias_name)
    from = from_clause(target, child_alias, rel, state.alias_name)

    # The embed's own filters address the TARGET's columns, so they must render
    # with `state.relation` set to the target (see the #72 note in build_embed).
    {filt_sql, state} =
      render_filters(filters, child_alias, %{state | relation: target}, qe)

    state = %{state | relation: source}

    cond_sql = [join_sql, filt_sql] |> Enum.reject(&(&1 == "")) |> Enum.join(" AND ")
    where = if cond_sql == "", do: "", else: " WHERE " <> cond_sql
    count_sql = "(SELECT count(*) FROM #{from}#{where})"

    {if(present?, do: "#{count_sql} > 0", else: "#{count_sql} = 0"), state}
  end

  # Whether the null-filter asks for a present related row (semi-join). Base
  # `is.not_null` means present; `is.null` means absent; a `not.` prefix inverts.
  defp embed_presence?(%{value: value, negate: negate}) do
    base_present = String.downcase(value) == "not_null"
    base_present != negate
  end

  defp find_embed_node(select, name) do
    Enum.find(select, fn
      %{kind: :embed} = e -> e.alias == name or e.target == name
      _ -> false
    end)
  end

  defp exists_clause(e, rel, src_alias, own_filters, deeper_filters, state, qe) do
    %{relation: target, join_cond: join} = rel

    seq = state.embed_seq + 1
    state = %{state | embed_seq: seq}
    child_alias = "#{embed_alias(target.name, e.alias)}_x#{seq}"

    join_sql = render_join(join, child_alias, src_alias)

    # Render the embed's own filters (and any nested `!inner` propagation) in
    # the TARGET's scope, so column types resolve against the embedded relation.
    source = state.relation
    own_filters = rewrite_null_embed_filters(own_filters, e.select, deeper_filters)
    {filt_sql, state} = render_filters(own_filters, child_alias, %{state | relation: target}, qe)

    {nested, state} =
      inner_join_clauses(e.select, target, child_alias, deeper_filters, state, qe)

    state = %{state | relation: source}

    from = from_clause(target, child_alias, rel, src_alias)

    cond_sql =
      ([join_sql, filt_sql] ++ nested) |> Enum.reject(&(&1 == "")) |> Enum.join(" AND ")

    sql =
      "EXISTS (SELECT 1 FROM #{from}" <>
        if(cond_sql == "", do: "", else: " WHERE " <> cond_sql) <> ")"

    {sql, state}
  end

  # ---- order (advanced) ----------------------------------------------------

  @doc """
  Builds an `ORDER BY` clause for the aliased pipeline, supporting plain columns,
  json paths, computed columns (`schema.fn(alias)`), and related ordering
  (`order=<rel>(<col>)`), which orders by a column of a to-one embedded resource
  via a correlated scalar subquery.

  Related ordering validates against the request's `select` tree: the named
  relation must be embedded (else PGRST108) and must be to-one (else PGRST118).
  """
  def build_order_advanced([], _select, _relation, _al, state, _qe), do: {"", state}

  def build_order_advanced(terms, select, relation, al, state, qe) do
    {clauses, state} =
      Enum.map_reduce(terms, state, fn term, st ->
        build_order_term(term, select, relation, al, st, qe)
      end)

    {" ORDER BY " <> Enum.join(clauses, ", "), state}
  end

  # Related order term: order by a column of a to-one embedded resource.
  defp build_order_term(%{relation: rel_name} = term, select, relation, al, state, qe) do
    embed = find_order_embed(select, rel_name)

    if embed == nil do
      throw({:embed_error_raw, {:embed_not_selected, rel_name}})
    end

    rel = resolve_relationship(embed, relation, state.relations)

    if rel.kind != :one do
      throw({:embed_error_raw, {:related_order_not_to_one, relation.name, rel_name}})
    end

    %{relation: target, join_cond: join} = rel
    child_alias = "#{target.name}_o#{state.embed_seq + 1}"
    state = %{state | embed_seq: state.embed_seq + 1}

    join_sql = render_join(join, child_alias, al)
    from = from_clause(target, child_alias, rel, al)
    col_expr = qe.column_expr_aliased(term.column, term.json_path, child_alias, target)

    where = if join_sql == "", do: "", else: " WHERE " <> join_sql
    sub = "(SELECT #{col_expr} FROM #{from}#{where} LIMIT 1)"

    {sub <> dir_nulls(term), state}
  end

  # Computed-column / plain order term.
  defp build_order_term(%{column: col} = term, _select, relation, al, state, qe) do
    expr =
      if col in relation.computed_columns do
        "#{QE.quote_ident(relation.schema)}.#{QE.quote_ident(col)}(#{QE.quote_ident(al)})"
      else
        qe.column_expr_aliased(col, term.json_path, al, relation)
      end

    {expr <> dir_nulls(term), state}
  end

  defp dir_nulls(term) do
    dir = if term.dir == :desc, do: " DESC", else: " ASC"
    nulls = order_nulls(term.nulls)
    dir <> nulls
  end

  defp order_nulls(:first), do: " NULLS FIRST"
  defp order_nulls(:last), do: " NULLS LAST"
  defp order_nulls(:default), do: ""

  # Find the embed node a related-order term refers to. The order key uses the
  # embed's alias when aliased, otherwise the relation name (case 1212/1215).
  defp find_order_embed(select, name) do
    Enum.find(select, fn
      %{kind: :embed} = e -> (e.alias || e.target) == name or e.target == name
      _ -> false
    end)
  end

  # ---- group by ------------------------------------------------------------

  @doc """
  When the select mixes plain fields with aggregates, returns the implicit
  `GROUP BY` clause; otherwise `{"", ""}`.
  """
  def group_by(nodes, al, relation) do
    has_agg? = Enum.any?(nodes, &match?(%{kind: :agg}, &1))

    plain =
      Enum.filter(nodes, fn
        %{kind: :field} -> true
        _ -> false
      end)

    if has_agg? and plain != [] do
      exprs =
        Enum.map_join(plain, ", ", &QE.column_expr_aliased(&1.column, &1.json_path, al, relation))

      {" GROUP BY " <> exprs, ""}
    else
      {"", ""}
    end
  end

  # ---- relationship resolution --------------------------------------------

  defp resolve_relationship(e, source, relations) do
    candidates = candidate_relationships(source, e.target, e.hint, relations)

    case candidates do
      [one] ->
        one

      [] ->
        throw({:embed_error, no_relationship_error(source, e.target, e.hint)})

      many ->
        throw({:embed_error, ambiguous_error(source, e.target, many)})
    end
  end

  defp candidate_relationships(source, target_name, hint, relations) do
    all =
      m2o_candidates(source, target_name, relations) ++
        o2m_candidates(source, target_name, relations) ++
        Enum.sort_by(m2m_candidates(source, target_name, relations), & &1.constraint) ++
        computed_candidates(source, target_name, relations)

    case hint do
      nil -> all
      _ -> Enum.filter(all, &hint_matches?(&1, hint))
    end
  end

  defp hint_matches?(c, hint), do: hint in c.hint_names

  # Many-to-one / one-to-one (parent side): source has an FK to target. The
  # embed target may be named by the referenced relation, the FK constraint name
  # (1122), or the FK column name (1123); in the latter two the embed key is the
  # name the client used.
  defp m2o_candidates(source, target_name, relations) do
    source.foreign_keys
    |> Enum.filter(fn fk ->
      fk.ref_relation == target_name or fk.constraint == target_name or
        target_name in fk.columns
    end)
    |> Enum.map(fn fk ->
      target = Map.get(relations, {fk.ref_schema, fk.ref_relation})
      pairs = Enum.zip(fk.columns, fk.ref_columns) |> Enum.map(fn {src, ref} -> {ref, src} end)

      embed_key =
        if fk.ref_relation == target_name, do: fk.ref_relation, else: target_name

      %{
        relation: target,
        kind: :one,
        cardinality: "many-to-one",
        join_cond: {:direct, pairs},
        via: nil,
        embed_key: embed_key,
        constraint: fk.constraint,
        hint_names: [fk.constraint, fk.ref_relation | fk.columns],
        rel_desc:
          "#{fk.constraint} using #{source.name}(#{Enum.join(fk.columns, ", ")}) and #{fk.ref_relation}(#{Enum.join(fk.ref_columns, ", ")})"
      }
    end)
  end

  # One-to-many / one-to-one (child side): target has an FK to source.
  defp o2m_candidates(source, target_name, relations) do
    case Map.get(relations, {source.schema, target_name}) do
      nil ->
        []

      target ->
        target.foreign_keys
        |> Enum.filter(&(&1.ref_relation == source.name and &1.ref_schema == source.schema))
        |> Enum.map(fn fk ->
          kind = if fk.unique?, do: :one, else: :many
          pairs = Enum.zip(fk.columns, fk.ref_columns)

          %{
            relation: target,
            kind: kind,
            cardinality: if(kind == :one, do: "one-to-one", else: "one-to-many"),
            join_cond: {:direct, pairs},
            via: nil,
            embed_key: target_name,
            constraint: fk.constraint,
            hint_names: [fk.constraint, target_name | fk.columns],
            rel_desc:
              "#{fk.constraint} using #{source.name}(#{Enum.join(fk.ref_columns, ", ")}) and #{target.name}(#{Enum.join(fk.columns, ", ")})"
          }
        end)
    end
  end

  # Many-to-many: a junction J has an FK to source and an FK to target.
  defp m2m_candidates(source, target_name, relations) do
    case Map.get(relations, {source.schema, target_name}) do
      nil ->
        []

      target ->
        relations
        |> Map.values()
        |> Enum.reject(&(&1.schema != source.schema or &1.name in [source.name, target.name]))
        |> Enum.flat_map(&junction_candidates(&1, source, target, target_name))
    end
  end

  # All m2m relationships routed through one junction relation: the cartesian
  # product of its FKs into `source` with its FKs into `target`.
  defp junction_candidates(jrel, source, target, target_name) do
    fks_to_source =
      Enum.filter(
        jrel.foreign_keys,
        &(&1.ref_relation == source.name and &1.ref_schema == source.schema)
      )

    fks_to_target =
      Enum.filter(
        jrel.foreign_keys,
        &(&1.ref_relation == target.name and &1.ref_schema == target.schema)
      )

    for fs <- fks_to_source, ft <- fks_to_target do
      jpairs = Enum.zip(fs.columns, fs.ref_columns)
      tpairs = Enum.zip(ft.columns, ft.ref_columns)

      %{
        relation: target,
        kind: :many,
        cardinality: "many-to-many",
        join_cond: {:via, jpairs, tpairs},
        via: {jrel, ft},
        embed_key: target_name,
        constraint: jrel.name,
        hint_names: [jrel.name, target_name, fs.constraint, ft.constraint],
        rel_desc:
          "#{jrel.name} using #{fs.constraint}(#{Enum.join(fs.columns, ", ")}) and #{ft.constraint}(#{Enum.join(ft.columns, ", ")})"
      }
    end
  end

  # Computed relationships: a SETOF-returning function f(source) -> target.
  defp computed_candidates(source, target_name, relations) do
    source.computed_relations
    |> Enum.filter(&(&1.name == target_name))
    |> Enum.map(fn cr ->
      target = Map.get(relations, {cr.ref_schema, cr.ref_relation})
      kind = if cr.rows == 1 or cr.rows == 1.0, do: :one, else: :many

      %{
        relation: target,
        kind: kind,
        cardinality: if(kind == :one, do: "many-to-one", else: "one-to-many"),
        join_cond: :computed,
        via: nil,
        computed: {source.schema, cr.name},
        embed_key: target_name,
        constraint: cr.name,
        hint_names: [cr.name],
        rel_desc: "#{cr.name} computed"
      }
    end)
  end

  # ---- embed filter routing ------------------------------------------------

  defp embed_segment(e, rel), do: e.alias || rel.embed_key || e.target

  # Split embed-keyed orders between this embed (`own`, accumulated with `++`)
  # and deeper embeds (re-keyed by the remaining path).
  defp pop_embed_orders(embed_orders, segments) do
    pop_embed_routed(embed_orders, segments, [], fn own, terms -> own ++ terms end)
  end

  # Like `pop_embed_orders`, but each embed path maps to a single integer (limit
  # or offset). Returns `{own_value | nil, deeper_map}`.
  defp pop_embed_paged(embed_paged, segments) do
    pop_embed_routed(embed_paged, segments, nil, fn _own, value -> value end)
  end

  # Route each `{path, value}` entry: a single-segment path naming this embed is
  # merged into `own` via `merge`; a longer path naming this embed is re-keyed by
  # its tail for the child scope; anything else is dropped.
  defp pop_embed_routed(entries, segments, initial, merge) do
    Enum.reduce(entries, {initial, %{}}, fn {path, value}, {own, deeper} = acc ->
      case {path, List.first(path) in segments} do
        {[_head], true} -> {merge.(own, value), deeper}
        {[_head | rest], true} when rest != [] -> {own, Map.put(deeper, rest, value)}
        _ -> acc
      end
    end)
  end

  defp paginate_sql(limit, offset) do
    limit_sql = if is_integer(limit), do: " LIMIT #{limit}", else: ""
    offset_sql = if is_integer(offset) and offset > 0, do: " OFFSET #{offset}", else: ""
    limit_sql <> offset_sql
  end

  defp pop_embed_filters(embed_filters, segments) do
    pop_embed_routed(embed_filters, segments, [], fn own, nodes -> own ++ nodes end)
  end

  # ---- error envelopes -----------------------------------------------------

  defp no_relationship_error(source, target_name, hint) do
    hint_clause = if hint, do: " using the hint '#{hint}'", else: ""

    %{
      status: 400,
      body: %{
        code: "PGRST200",
        message:
          "Could not find a relationship between '#{source.name}' and '#{target_name}' in the schema cache",
        details:
          "Searched for a foreign key relationship between '#{source.name}' and '#{target_name}'#{hint_clause} in the schema '#{source.schema}', but no matches were found.",
        hint: nil
      }
    }
  end

  defp ambiguous_error(source, target_name, candidates) do
    details =
      Enum.map(candidates, fn c ->
        %{
          cardinality: c.cardinality,
          relationship: c.rel_desc,
          embedding: "#{source.name} with #{target_name}"
        }
      end)

    suggestions =
      Enum.map_join(candidates, ", ", fn c -> "'#{target_name}!#{c.constraint}'" end)

    %{
      status: 300,
      body: %{
        code: "PGRST201",
        message:
          "Could not embed because more than one relationship was found for '#{source.name}' and '#{target_name}'",
        hint:
          "Try changing '#{target_name}' to one of the following: #{suggestions}. Find the desired relationship in the 'details' key.",
        details: details
      }
    }
  end

  # ---- small helpers -------------------------------------------------------

  defp embed_alias(name, nil), do: name
  defp embed_alias(_name, al), do: al

  defp col_expr(al, col), do: "#{QE.quote_ident(al)}.#{QE.quote_ident(col)}"
end
