defmodule Bier.Embed do
  @moduledoc """
  Resource embedding (PostgREST `select=...,rel(...)`) for the read pipeline.

  Given the parsed select tree, the source `Relation`, its SQL alias, and the
  full introspection map, this module produces:

    * `build_row_object/6` — a single JSON expression (`json_build_object(...)`)
      that the executor wraps in `json_agg`. Scalar fields, json-paths, casts,
      aggregates, computed columns, embeds (many-to-one / one-to-many /
      many-to-many / one-to-one / spread / computed relationships) are rendered
      here as correlated sub-queries.
    * `inner_join_where/6` — the extra `WHERE` predicate that an `!inner` embed
      (or an embedded filter that implies inner) adds to the *source* query so
      rows whose embedding is empty are dropped.
    * `group_by/2` — the implicit `GROUP BY` clause when plain fields are mixed
      with aggregates.

  Relationship resolution walks the foreign keys discovered by
  `Bier.Introspection`, plus computed relationships (SETOF-returning functions).
  Disambiguation errors (`PGRST200` / `PGRST201`) are thrown as
  `{:embed_error, body}` and turned into responses by the controller.
  """

  alias Bier.Introspection.Relation
  alias Bier.QueryExecutor, as: QE

  @doc """
  Build the JSON object expression for a single row of `relation` (aliased as
  `al`), given the select `nodes`. `embed_filters` maps embed paths to filter
  nodes. `qe` is the executor module (passed to avoid a compile cycle).
  """
  def build_row_object(nodes, %Relation{} = relation, al, embed_filters, state, qe) do
    {pairs_and_spreads, state} =
      Enum.flat_map_reduce(nodes, state, fn node, st ->
        build_node(node, relation, al, embed_filters, st, qe)
      end)

    {plain, spreads} =
      Enum.split_with(pairs_and_spreads, fn
        {:spread, _} -> false
        _ -> true
      end)

    obj = "json_build_object(" <> Enum.join(plain, ", ") <> ")"

    case spreads do
      [] ->
        {obj, state}

      _ ->
        merged =
          Enum.reduce(spreads, obj <> "::jsonb", fn {:spread, expr}, acc ->
            "(#{acc} || #{expr})"
          end)

        {"(#{merged})::json", state}
    end
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
    {[json_pair(name, expr)], state}
  end

  defp build_node(%{kind: :agg} = a, _relation, al, _ef, state, _qe) do
    inner =
      case a.column do
        nil -> "#{a.fun}(*)"
        col -> "#{a.fun}(#{col_expr(al, col)})"
      end

    inner = if a.cast, do: "#{inner}::#{QE.quote_type(a.cast)}", else: inner
    name = a.alias || a.fun
    {[json_pair(name, inner)], state}
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

  defp star_pairs(relation, al) do
    Enum.map(relation.columns, fn c ->
      json_pair(c.name, star_col_expr(relation, al, c.name))
    end)
  end

  # ---- scalar field expr ---------------------------------------------------

  defp field_expr(%{column: col} = f, relation, al) do
    base =
      if col in relation.computed_columns do
        "#{QE.quote_ident(relation.schema)}.#{QE.quote_ident(col)}(#{QE.quote_ident(al)})"
      else
        QE.column_expr_aliased(col, f.json_path, al)
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

    segment = embed_segment(e, rel)
    {own_filters, deeper_filters} = pop_embed_filters(ef, segment)

    # Embed order keys may reference the embed by its alias OR its real relation
    # name / embed key (case 1212: `the_tasks:tasks(...)` ordered via `tasks.order`).
    order_segments =
      Enum.uniq([segment, e.target, rel.embed_key, e.alias]) |> Enum.reject(&is_nil/1)

    {own_order, deeper_orders} = pop_embed_orders(state.embed_orders, order_segments)
    {own_limit, deeper_limits} = pop_embed_paged(state.embed_limits, order_segments)
    {own_offset, deeper_offsets} = pop_embed_paged(state.embed_offsets, order_segments)

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

    {child_obj, state} =
      build_row_object(e.select, target, child_alias, deeper_filters, child_scope, qe)

    state = struct!(state, saved)

    {where_sql, state} =
      build_embed_where(join, own_filters, child_alias, src_alias, state, qe)

    {order_sql, state} =
      build_order_advanced(own_order, e.select, target, child_alias, state, qe)

    page_sql = paginate_sql(own_limit, own_offset)

    from = from_clause(target, child_alias, rel, src_alias)

    sub =
      case kind do
        :one ->
          inner = "SELECT #{child_obj} AS __c__ FROM #{from}#{where_sql}#{order_sql} LIMIT 1"
          "(SELECT __c__ FROM (#{inner}) __sub__)"

        :many ->
          inner = "SELECT #{child_obj} AS __c__ FROM #{from}#{where_sql}#{order_sql}#{page_sql}"
          "COALESCE((SELECT json_agg(__c__) FROM (#{inner}) __sub__), '[]'::json)"
      end

    if e.spread do
      {[{:spread, spread_expr(sub, kind, e.select, target)}], state}
    else
      {[json_pair(out_name, sub)], state}
    end
  end

  # Spread merges the embedded object's keys into the parent row. For a missing
  # many-to-one parent the keys must still appear with null values (a LEFT JOIN
  # in PostgREST), so coalesce to a template object of {key: null, ...}.
  defp spread_expr(sub, :one, select, target) do
    "COALESCE(#{sub}, #{null_template(select, target)})::jsonb"
  end

  defp spread_expr(sub, :many, _select, _target) do
    "COALESCE(#{sub}, '[]'::json)::jsonb"
  end

  # A json object with every output key of `select` mapped to null. Used to keep
  # spread keys present when the parent row is missing.
  defp null_template(select, target) do
    pairs =
      select
      |> Enum.flat_map(fn
        :star -> Enum.map(target.columns, & &1.name)
        %{kind: :star} -> Enum.map(target.columns, & &1.name)
        %{kind: :field} = f -> [f.alias || QE.json_output_name(f.column, f.json_path)]
        %{kind: :agg} = a -> [a.alias || a.fun]
        _ -> []
      end)
      |> Enum.map_join(", ", fn key -> "#{QE.pg_literal(key)}, null" end)

    "json_build_object(#{pairs})"
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

  defp build_embed_where(join, own_filters, child_alias, src_alias, state, qe) do
    join_sql = render_join(join, child_alias, src_alias)

    {filt_sql, state} = render_filters(own_filters, child_alias, state, qe)

    combined =
      [join_sql, filt_sql]
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
  Builds the WHERE predicate added to the *source* query for `!inner` embeds
  (and embeds that carry a filter, which imply inner).
  """
  def inner_join_where(nodes, %Relation{} = relation, al, embed_filters, state, qe) do
    {clauses, state} =
      Enum.flat_map_reduce(nodes, state, fn
        %{kind: :embed} = e, st ->
          rel = resolve_relationship(e, relation, st.relations)
          {own_filters, _deeper} = pop_embed_filters(embed_filters, embed_segment(e, rel))
          # Only an explicit `!inner` propagates an embedded filter to the parent
          # (dropping parents with no matching child). The default (left) join
          # applies the filter to the embedded rows only and keeps every parent
          # row, with an empty array where nothing matches (case 1182 vs 1181).
          if e.join == :inner do
            {sql, st2} = exists_clause(e, rel, al, own_filters, st, qe)
            {[sql], st2}
          else
            {[], st}
          end

        _other, st ->
          {[], st}
      end)

    where =
      case clauses do
        [] -> ""
        list -> " WHERE " <> Enum.join(list, " AND ")
      end

    {where, state}
  end

  @doc """
  Builds the WHERE predicate for null-filtering on embedded resources, i.e.
  `<embed>=is.null` (anti-join: keep parents with NO related row) and
  `<embed>=not.is.null` (semi-join: keep parents WITH a related row).

  `filters` are leaf filter nodes whose `column` names a selected embed.
  """
  def null_filter_where([], _select, _relation, _al, state, _qe), do: {"", state}

  def null_filter_where(filters, select, relation, al, state, _qe) do
    clauses =
      Enum.map(filters, fn f ->
        e = find_embed_node(select, f.column)
        rel = resolve_relationship(e, relation, state.relations)
        count_sql = related_count_subquery(e, rel, al)
        # A correlated scalar `count(*)` subquery cannot be pulled up into a
        # semi/anti-join, so the parent scan order is preserved (matching
        # PostgREST's LATERAL-based null filtering). `> 0` keeps parents that
        # HAVE a related row (semi-join); `= 0` keeps those with NONE (anti-join).
        if embed_presence?(f), do: "#{count_sql} > 0", else: "#{count_sql} = 0"
      end)

    where =
      case clauses do
        [] -> ""
        list -> " WHERE " <> Enum.join(list, " AND ")
      end

    {where, state}
  end

  defp related_count_subquery(e, rel, src_alias) do
    %{relation: target, join_cond: join} = rel
    child_alias = embed_alias(target.name, e.alias) <> "_n"
    join_sql = render_join(join, child_alias, src_alias)
    from = from_clause(target, child_alias, rel, src_alias)
    where = if join_sql == "", do: "", else: " WHERE " <> join_sql
    "(SELECT count(*) FROM #{from}#{where})"
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

  defp exists_clause(e, rel, src_alias, own_filters, state, qe) do
    %{relation: target, join_cond: join} = rel
    child_alias = embed_alias(target.name, e.alias) <> "_x"

    join_sql = render_join(join, child_alias, src_alias)
    {filt_sql, state} = render_filters(own_filters, child_alias, state, qe)

    from = from_clause(target, child_alias, rel, src_alias)

    cond_sql =
      [join_sql, filt_sql] |> Enum.reject(&(&1 == "")) |> Enum.join(" AND ")

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
    col_expr = qe.column_expr_aliased(term.column, term.json_path, child_alias)

    where = if join_sql == "", do: "", else: " WHERE " <> join_sql
    sub = "(SELECT #{col_expr} FROM #{from}#{where} LIMIT 1)"

    {sub <> dir_nulls(term), state}
  end

  # Computed-column / composite / plain order term.
  defp build_order_term(%{column: col} = term, _select, relation, al, state, qe) do
    expr =
      cond do
        col in relation.computed_columns ->
          "#{QE.quote_ident(relation.schema)}.#{QE.quote_ident(col)}(#{QE.quote_ident(al)})"

        term.json_path != [] and composite_column?(relation, col) ->
          composite_field_expr(al, col, term.json_path)

        true ->
          qe.column_expr_aliased(col, term.json_path, al)
      end

    {expr <> dir_nulls(term), state}
  end

  defp composite_column?(relation, col) do
    case Enum.find(relation.columns, &(&1.name == col)) do
      %{composite?: true} -> true
      _ -> false
    end
  end

  # Field access on a composite-typed column: `(alias."col")."field"`. The text
  # arrow (`->>`) additionally casts to text, mirroring PostgREST.
  defp composite_field_expr(al, col, [{kind, key}]) do
    base = "(#{QE.quote_ident(al)}.#{QE.quote_ident(col)}).#{QE.quote_ident(key)}"
    if kind == :arrow_text, do: "#{base}::text", else: base
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
  def group_by(nodes, al) do
    has_agg? = Enum.any?(nodes, &match?(%{kind: :agg}, &1))

    plain =
      Enum.filter(nodes, fn
        %{kind: :field} -> true
        _ -> false
      end)

    if has_agg? and plain != [] do
      exprs = Enum.map_join(plain, ", ", &QE.column_expr_aliased(&1.column, &1.json_path, al))
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

  defp pop_embed_filters(embed_filters, segment) do
    Enum.reduce(embed_filters, {[], %{}}, fn {path, nodes}, {own, deeper} ->
      case path do
        [^segment] ->
          {own ++ nodes, deeper}

        [^segment | rest] when rest != [] ->
          {own, Map.put(deeper, rest, nodes)}

        _ ->
          {own, deeper}
      end
    end)
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

  defp json_pair(key, expr), do: "#{QE.pg_literal(key)}, #{expr}"

  defp col_expr(al, col), do: "#{QE.quote_ident(al)}.#{QE.quote_ident(col)}"
end
