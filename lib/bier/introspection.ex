defmodule Bier.Introspection do
  @moduledoc """
  Database introspection.

  Queries `pg_catalog` for the relations (tables and views) exposed across the
  configured `db_schemas`, along with their columns, primary keys, and foreign
  keys. Foreign keys are needed by the request pipeline for resource embedding.

  The result is a map keyed by `{schema, relation}` so the router/controller can
  resolve a request target in constant time:

      %{
        {"test", "items"} => %Bier.Introspection.Relation{
          schema: "test",
          name: "items",
          kind: :table | :view,
          columns: [%{name: "id", type: "bigint", pk?: true, notnull?: true, default: ...}, ...],
          primary_key: ["id"],
          foreign_keys: [%{columns: ["client_id"], ref_schema: "test", ref_relation: "clients", ref_columns: ["id"], constraint: "..."}]
        },
        ...
      }
  """

  defmodule Relation do
    @moduledoc "A single exposed relation (table or view) with its structure."

    @type column :: %{
            name: String.t(),
            type: String.t(),
            pk?: boolean(),
            notnull?: boolean(),
            default: String.t() | nil,
            composite?: boolean()
          }

    @type foreign_key :: %{
            constraint: String.t(),
            columns: [String.t()],
            ref_schema: String.t(),
            ref_relation: String.t(),
            ref_columns: [String.t()],
            unique?: boolean()
          }

    @type t :: %__MODULE__{
            schema: String.t(),
            name: String.t(),
            kind: :table | :view,
            columns: [column()],
            primary_key: [String.t()],
            foreign_keys: [foreign_key()],
            computed_columns: [String.t()],
            computed_relations: [map()]
          }

    defstruct schema: nil,
              name: nil,
              kind: :table,
              columns: [],
              primary_key: [],
              foreign_keys: [],
              computed_columns: [],
              computed_relations: []
  end

  @type t :: %{optional({String.t(), String.t()}) => Relation.t()}

  @doc """
  Introspects `schemas` over the given Postgrex connection.

  Returns a map keyed by `{schema, relation}`.
  """
  @spec run(conn :: term(), schemas :: [String.t()]) :: t()
  def run(conn, schemas) when is_list(schemas) and schemas != [] do
    relations = query_relations(conn, schemas)
    columns = query_columns(conn, schemas)
    foreign_keys = query_foreign_keys(conn, schemas)
    computed = query_computed(conn, schemas)
    view_fks = infer_view_foreign_keys(conn, schemas, foreign_keys, relations)
    view_pks = infer_view_primary_keys(conn, schemas)

    columns_by_rel = Enum.group_by(columns, &{&1.schema, &1.relation})
    fks_by_rel = Enum.group_by(foreign_keys ++ view_fks, &{&1.schema, &1.relation})
    comp_cols_by_rel = Enum.group_by(computed.columns, &{&1.schema, &1.relation})
    comp_rels_by_rel = Enum.group_by(computed.relations, &{&1.schema, &1.relation})

    for {{schema, name}, kind} <- relations, into: %{} do
      cols =
        columns_by_rel
        |> Map.get({schema, name}, [])
        |> Enum.sort_by(& &1.position)
        |> Enum.map(fn c ->
          %{
            name: c.name,
            type: c.type,
            pk?: c.pk?,
            notnull?: c.notnull?,
            default: c.default,
            composite?: c.composite?
          }
        end)

      pk =
        case cols |> Enum.filter(& &1.pk?) |> Enum.map(& &1.name) do
          [] -> Map.get(view_pks, {schema, name}, [])
          base_pk -> base_pk
        end

      fks =
        fks_by_rel
        |> Map.get({schema, name}, [])
        |> Enum.map(fn fk ->
          %{
            constraint: fk.constraint,
            columns: fk.columns,
            ref_schema: fk.ref_schema,
            ref_relation: fk.ref_relation,
            ref_columns: fk.ref_columns,
            unique?: fk.unique?
          }
        end)

      comp_cols =
        comp_cols_by_rel |> Map.get({schema, name}, []) |> Enum.map(& &1.name)

      comp_rels =
        comp_rels_by_rel
        |> Map.get({schema, name}, [])
        |> Enum.map(fn r ->
          %{
            name: r.name,
            ref_schema: r.ref_schema,
            ref_relation: r.ref_relation,
            rows: r.rows
          }
        end)

      {{schema, name},
       %Relation{
         schema: schema,
         name: name,
         kind: kind,
         columns: cols,
         primary_key: pk,
         foreign_keys: fks,
         computed_columns: comp_cols,
         computed_relations: comp_rels
       }}
    end
  end

  @doc """
  Introspect callable functions that return `SETOF <relation>` across `schemas`.

  Returns a map keyed by `{schema, function_name}` (functions can be overloaded;
  the conformance pagination functions are not, so we keep the last definition
  per name). Each entry carries the ordered argument names/types and the
  relation the function returns a set of, so the request pipeline can call the
  function as a table-valued source and project/filter its columns.
  """
  @spec functions(conn :: term(), schemas :: [String.t()]) :: %{
          optional({String.t(), String.t()}) => map()
        }
  def functions(conn, schemas) when is_list(schemas) and schemas != [] do
    sql = """
    SELECT
      pn.nspname AS schema,
      p.proname  AS name,
      COALESCE(p.proargnames, ARRAY[]::text[]) AS arg_names,
      (
        SELECT array_agg(format_type(t, NULL) ORDER BY ord)
        FROM unnest(p.proargtypes) WITH ORDINALITY AS u(t, ord)
      ) AS arg_types,
      ret_n.nspname AS ret_schema,
      ret_rel.relname AS ret_relation,
      p.proretset AS retset,
      ret_t.typtype AS ret_typtype,
      format_type(p.prorettype, NULL) AS ret_type,
      p.pronargs AS nargs
    FROM pg_proc p
    JOIN pg_namespace pn ON pn.oid = p.pronamespace
    JOIN pg_type ret_t ON ret_t.oid = p.prorettype
    LEFT JOIN pg_class ret_rel ON ret_rel.oid = ret_t.typrelid
    LEFT JOIN pg_namespace ret_n ON ret_n.oid = ret_rel.relnamespace
    WHERE pn.nspname = ANY($1)
      AND p.prokind = 'f'
    """

    %Postgrex.Result{rows: rows} = Postgrex.query!(conn, sql, [schemas])

    for [
          schema,
          name,
          arg_names,
          arg_types,
          ret_schema,
          ret_relation,
          retset,
          ret_typtype,
          ret_type,
          nargs
        ] <- rows,
        into: %{} do
      arg_names = arg_names || []
      arg_types = arg_types || []

      args =
        arg_types
        |> Enum.with_index()
        |> Enum.map(fn {t, i} -> %{name: Enum.at(arg_names, i) || "", type: t} end)

      ret_kind = ret_kind(retset, ret_typtype, ret_relation, ret_type)
      # A single unnamed argument means the body is passed positionally (scalar
      # body / octet-stream / single json param) rather than as named args.
      single_unnamed? = nargs == 1 and (arg_names == [] or Enum.at(arg_names, 0) in [nil, ""])

      {{schema, name},
       %{
         schema: schema,
         name: name,
         args: args,
         ret_schema: ret_schema,
         ret_relation: ret_relation,
         retset: retset,
         ret_kind: ret_kind,
         ret_type: ret_type,
         single_unnamed?: single_unnamed?
       }}
    end
  end

  @doc """
  Introspect custom media-type handlers across `schemas`.

  PostgREST models a custom media type as a `DOMAIN` whose name is the MIME
  string, and a handler as an aggregate whose transition state type is that
  domain. The aggregate's first argument type is the relation (or `anyelement`)
  the handler applies to. Returns a list of handler maps.
  """
  @spec media_handlers(conn :: term(), schemas :: [String.t()]) :: [map()]
  def media_handlers(conn, schemas) when is_list(schemas) and schemas != [] do
    sql = """
    SELECT
      an.nspname AS agg_schema,
      ap.proname AS agg_name,
      dt.typname AS media_type,
      at_n.nspname AS arg_schema,
      at_rel.relname AS arg_relation,
      format_type(ap.proargtypes[0], NULL) AS arg_type,
      a.aggfinalfn <> 0 AS has_final
    FROM pg_aggregate a
    JOIN pg_proc ap ON ap.oid = a.aggfnoid
    JOIN pg_namespace an ON an.oid = ap.pronamespace
    JOIN pg_type st ON st.oid = a.aggtranstype
    JOIN pg_type dt ON dt.oid = st.oid AND dt.typtype = 'd'
    LEFT JOIN pg_type arg_t ON arg_t.oid = ap.proargtypes[0]
    LEFT JOIN pg_class at_rel ON at_rel.oid = arg_t.typrelid
    LEFT JOIN pg_namespace at_n ON at_n.oid = at_rel.relnamespace
    WHERE an.nspname = ANY($1)
      AND dt.typname LIKE '%/%'
    """

    %Postgrex.Result{rows: rows} = Postgrex.query!(conn, sql, [schemas])

    for [agg_schema, agg_name, media_type, arg_schema, arg_relation, arg_type, has_final] <-
          rows do
      %{
        agg_schema: agg_schema,
        agg_name: agg_name,
        media_type: media_type,
        arg_schema: arg_schema,
        arg_relation: arg_relation,
        arg_type: arg_type,
        has_final: has_final
      }
    end
  end

  # Classify a function's return for the RPC pipeline.
  defp ret_kind(_retset, _typtype, _ret_relation, "void"), do: :void
  defp ret_kind(true, "c", ret_relation, _ret_type) when not is_nil(ret_relation), do: :setof_rel
  defp ret_kind(true, "c", _ret_relation, _ret_type), do: :setof_record
  defp ret_kind(false, "c", ret_relation, _ret_type) when not is_nil(ret_relation), do: :composite
  defp ret_kind(true, _typtype, _ret_relation, _ret_type), do: :setof_scalar
  defp ret_kind(false, _typtype, _ret_relation, _ret_type), do: :scalar

  # Tables (r), views (v), materialized views (m), foreign tables (f),
  # partitioned tables (p).
  defp query_relations(conn, schemas) do
    sql = """
    SELECT n.nspname AS schema, c.relname AS name, c.relkind AS kind
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = ANY($1)
      AND c.relkind = ANY(ARRAY['r','v','m','f','p'])
    """

    %Postgrex.Result{rows: rows} = Postgrex.query!(conn, sql, [schemas])

    for [schema, name, kind] <- rows, into: %{} do
      {{schema, name}, relkind(kind)}
    end
  end

  defp relkind("v"), do: :view
  defp relkind("m"), do: :view
  defp relkind(_), do: :table

  defp query_columns(conn, schemas) do
    sql = """
    SELECT
      n.nspname AS schema,
      c.relname AS relation,
      a.attname AS name,
      format_type(a.atttypid, a.atttypmod) AS type,
      a.attnum AS position,
      a.attnotnull AS notnull,
      pg_get_expr(ad.adbin, ad.adrelid) AS default,
      COALESCE(pk.is_pk, false) AS is_pk,
      (at.typtype = 'c') AS is_composite
    FROM pg_attribute a
    JOIN pg_class c ON c.oid = a.attrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_type at ON at.oid = a.atttypid
    LEFT JOIN pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
    LEFT JOIN (
      SELECT i.indrelid, a2.attnum, true AS is_pk
      FROM pg_index i
      JOIN pg_attribute a2 ON a2.attrelid = i.indrelid AND a2.attnum = ANY(i.indkey)
      WHERE i.indisprimary
    ) pk ON pk.indrelid = a.attrelid AND pk.attnum = a.attnum
    WHERE n.nspname = ANY($1)
      AND c.relkind = ANY(ARRAY['r','v','m','f','p'])
      AND a.attnum > 0
      AND NOT a.attisdropped
    """

    %Postgrex.Result{rows: rows} = Postgrex.query!(conn, sql, [schemas])

    for [schema, relation, name, type, position, notnull, default, is_pk, is_composite] <- rows do
      %{
        schema: schema,
        relation: relation,
        name: name,
        type: type,
        position: position,
        notnull?: notnull,
        default: default,
        pk?: is_pk,
        composite?: is_composite
      }
    end
  end

  defp query_foreign_keys(conn, schemas) do
    sql = """
    SELECT
      n.nspname AS schema,
      c.relname AS relation,
      con.conname AS constraint,
      (
        SELECT array_agg(att.attname ORDER BY u.ord)
        FROM unnest(con.conkey) WITH ORDINALITY AS u(attnum, ord)
        JOIN pg_attribute att ON att.attrelid = con.conrelid AND att.attnum = u.attnum
      ) AS columns,
      fn.nspname AS ref_schema,
      fc.relname AS ref_relation,
      (
        SELECT array_agg(att.attname ORDER BY u.ord)
        FROM unnest(con.confkey) WITH ORDINALITY AS u(attnum, ord)
        JOIN pg_attribute att ON att.attrelid = con.confrelid AND att.attnum = u.attnum
      ) AS ref_columns,
      -- The FK is "unique" (=> one-to-one when embedded as parent's child) when
      -- the constrained columns are exactly covered by a unique index / PK on
      -- the source table.
      EXISTS (
        SELECT 1 FROM pg_index ix
        WHERE ix.indrelid = con.conrelid
          AND (ix.indisunique OR ix.indisprimary)
          AND (
            SELECT array_agg(k ORDER BY k) FROM unnest(ix.indkey::int[]) AS k
          ) = (
            SELECT array_agg(k::int ORDER BY k::int) FROM unnest(con.conkey) AS k
          )
      ) AS is_unique
    FROM pg_constraint con
    JOIN pg_class c ON c.oid = con.conrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_class fc ON fc.oid = con.confrelid
    JOIN pg_namespace fn ON fn.oid = fc.relnamespace
    WHERE con.contype = 'f'
      AND n.nspname = ANY($1)
    """

    %Postgrex.Result{rows: rows} = Postgrex.query!(conn, sql, [schemas])

    for [schema, relation, constraint, columns, ref_schema, ref_relation, ref_columns, is_unique] <-
          rows do
      %{
        schema: schema,
        relation: relation,
        constraint: constraint,
        columns: columns,
        ref_schema: ref_schema,
        ref_relation: ref_relation,
        ref_columns: ref_columns,
        unique?: is_unique
      }
    end
  end

  # View foreign keys.
  #
  # PostgREST lets a view participate in embeddings by *inheriting* the foreign
  # keys of the base tables it draws from. We reconstruct this by mapping each
  # view column to the base-table column it projects (via `pg_rewrite`/
  # `pg_depend`), then for every base-table FK whose source columns are all
  # exposed under the same names by the view, we emit an equivalent FK keyed on
  # the view (keeping the original constraint name, as PostgREST does).
  defp infer_view_foreign_keys(conn, schemas, base_fks, relations) do
    sql = """
    SELECT DISTINCT
      sch.nspname  AS view_schema,
      v.relname    AS view_name,
      vcol.attname AS view_column,
      srcsch.nspname AS src_schema,
      src.relname  AS src_relation,
      scol.attname AS src_column
    FROM pg_rewrite r
    JOIN pg_class v ON v.oid = r.ev_class AND v.relkind IN ('v','m')
    JOIN pg_namespace sch ON sch.oid = v.relnamespace
    JOIN pg_depend d
      ON d.objid = r.oid
     AND d.classid = 'pg_rewrite'::regclass
     AND d.refclassid = 'pg_class'::regclass
     AND d.deptype = 'n'
    JOIN pg_class src ON src.oid = d.refobjid AND src.relkind IN ('r','p')
    JOIN pg_namespace srcsch ON srcsch.oid = src.relnamespace
    JOIN pg_attribute scol
      ON scol.attrelid = src.oid AND scol.attnum = d.refobjsubid AND scol.attnum > 0
    JOIN pg_attribute vcol
      ON vcol.attrelid = v.oid AND vcol.attname = scol.attname AND vcol.attnum > 0
    WHERE sch.nspname = ANY($1)
    """

    %Postgrex.Result{rows: rows} = Postgrex.query!(conn, sql, [schemas])

    # Map: {view_schema, view_name, src_schema, src_relation} =>
    #        %{src_column => view_column}
    mapping =
      Enum.reduce(rows, %{}, fn [vsch, vname, vcol, ssch, srel, scol], acc ->
        key = {vsch, vname, ssch, srel}
        Map.update(acc, key, %{scol => vcol}, &Map.put(&1, scol, vcol))
      end)

    fks_by_src = Enum.group_by(base_fks, &{&1.schema, &1.relation})

    for {{vsch, vname, ssch, srel}, colmap} <- mapping,
        fk <- Map.get(fks_by_src, {ssch, srel}, []),
        Enum.all?(fk.columns, &Map.has_key?(colmap, &1)) do
      # When the referenced relation is exposed under the *view's own* schema
      # (the area-schema mirror case, e.g. `ordering.tasks` -> `ordering.projects`),
      # point the inferred FK there so embeddings resolve within the exposed
      # schema rather than dangling into the base `test` schema.
      {ref_schema, ref_relation} =
        if Map.has_key?(relations, {vsch, fk.ref_relation}) do
          {vsch, fk.ref_relation}
        else
          {fk.ref_schema, fk.ref_relation}
        end

      %{
        schema: vsch,
        relation: vname,
        constraint: fk.constraint,
        columns: Enum.map(fk.columns, &Map.fetch!(colmap, &1)),
        ref_schema: ref_schema,
        ref_relation: ref_relation,
        ref_columns: fk.ref_columns,
        # Inherit the base FK's uniqueness so a one-to-one base relationship
        # (e.g. a PK that is also an FK, like `trash_details.id`) stays one-to-one
        # when embedded through the mirror view.
        unique?: fk.unique?
      }
    end
  end

  # View primary keys.
  #
  # A view that projects every column of its base table's primary key (under the
  # same names) inherits that PK. PostgREST uses the base PK to build `Location`
  # headers and resolve PUT upserts against mirror views. We map each view column
  # to the base column it projects (via `pg_rewrite`/`pg_depend`), then for every
  # base PK whose columns are all exposed by the view, emit the view's PK as the
  # mapped view column names.
  defp infer_view_primary_keys(conn, schemas) do
    sql = """
    WITH view_cols AS (
      SELECT DISTINCT
        sch.nspname  AS view_schema,
        v.relname    AS view_name,
        src.oid      AS src_oid,
        scol.attname AS src_column,
        vcol.attname AS view_column
      FROM pg_rewrite r
      JOIN pg_class v ON v.oid = r.ev_class AND v.relkind IN ('v','m')
      JOIN pg_namespace sch ON sch.oid = v.relnamespace
      JOIN pg_depend d
        ON d.objid = r.oid
       AND d.classid = 'pg_rewrite'::regclass
       AND d.refclassid = 'pg_class'::regclass
       AND d.deptype = 'n'
      JOIN pg_class src ON src.oid = d.refobjid AND src.relkind IN ('r','p')
      JOIN pg_attribute scol
        ON scol.attrelid = src.oid AND scol.attnum = d.refobjsubid AND scol.attnum > 0
      JOIN pg_attribute vcol
        ON vcol.attrelid = v.oid AND vcol.attname = scol.attname AND vcol.attnum > 0
      WHERE sch.nspname = ANY($1)
    ),
    base_pk AS (
      SELECT i.indrelid AS src_oid, a.attname AS pk_column, k.ord
      FROM pg_index i
      JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord) ON true
      JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
      WHERE i.indisprimary
    )
    SELECT vc.view_schema, vc.view_name, vc.view_column, bp.ord
    FROM view_cols vc
    JOIN base_pk bp ON bp.src_oid = vc.src_oid AND bp.pk_column = vc.src_column
    ORDER BY vc.view_schema, vc.view_name, bp.ord
    """

    %Postgrex.Result{rows: rows} = Postgrex.query!(conn, sql, [schemas])

    rows
    |> Enum.group_by(fn [vsch, vname, _col, _ord] -> {vsch, vname} end)
    |> Map.new(fn {key, group} ->
      cols =
        group
        |> Enum.sort_by(fn [_s, _n, _c, ord] -> ord end)
        |> Enum.map(fn [_s, _n, col, _ord] -> col end)
        |> Enum.uniq()

      {key, cols}
    end)
  end

  # Computed columns and computed relationships.
  #
  # A function `f(rel)` defined in one of the exposed schemas whose single
  # argument is the composite row type of an exposed relation is a "computed
  # member" of that relation:
  #
  #   * returns a scalar (non-set, non-composite) => computed column
  #   * returns SETOF <other relation> => computed relationship (ROWS estimate
  #     decides cardinality: ROWS 1 => many-to-one single object).
  defp query_computed(conn, schemas) do
    sql = """
    SELECT
      pn.nspname    AS schema,
      arg_rel.relname AS relation,
      p.proname     AS name,
      p.proretset   AS retset,
      ret_n.nspname AS ret_schema,
      ret_rel.relname AS ret_relation,
      p.prorows     AS rows,
      ret_t.typtype AS ret_typtype
    FROM pg_proc p
    JOIN pg_namespace pn ON pn.oid = p.pronamespace
    JOIN pg_type arg_t ON arg_t.oid = p.proargtypes[0]
    JOIN pg_class arg_rel ON arg_rel.oid = arg_t.typrelid
    JOIN pg_namespace arg_n ON arg_n.oid = arg_rel.relnamespace
    JOIN pg_type ret_t ON ret_t.oid = p.prorettype
    LEFT JOIN pg_class ret_rel ON ret_rel.oid = ret_t.typrelid
    LEFT JOIN pg_namespace ret_n ON ret_n.oid = ret_rel.relnamespace
    WHERE pn.nspname = ANY($1)
      AND p.pronargs = 1
      AND arg_t.typtype = 'c'
      AND arg_n.nspname = ANY($1)
    """

    %Postgrex.Result{rows: rows} = Postgrex.query!(conn, sql, [schemas])

    {cols, rels} =
      Enum.reduce(rows, {[], []}, fn
        [schema, relation, name, retset, ret_schema, ret_relation, nrows, ret_typtype],
        {cols, rels} ->
          cond do
            # SETOF composite that maps to a real relation => computed relationship
            retset and ret_typtype == "c" and ret_relation != nil ->
              {cols,
               [
                 %{
                   schema: schema,
                   relation: relation,
                   name: name,
                   ref_schema: ret_schema,
                   ref_relation: ret_relation,
                   rows: nrows
                 }
                 | rels
               ]}

            # scalar, non-set => computed column
            not retset and ret_typtype != "c" ->
              {[%{schema: schema, relation: relation, name: name} | cols], rels}

            true ->
              {cols, rels}
          end
      end)

    %{columns: cols, relations: rels}
  end
end
