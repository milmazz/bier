defmodule Mix.Tasks.Bier.Fixtures.Load do
  @shortdoc "Drops/creates bier_test, loads conformance fixtures, mirrors area schemas"

  @moduledoc """
  Loads the conformance fixture database.

  Idempotent. Steps:

    1. Drop and (re)create the `bier_test` database.
    2. Ensure the `postgrest_test_*` roles exist (the fixtures also create them
       idempotently; this is a belt-and-suspenders for shared clusters).
    3. Load `spec/conformance/fixtures.sql` with `psql -v ON_ERROR_STOP=1`.
    4. Mirror schema `test` into each pure table/data area schema
       (`operators`, `ordering`, `pagination`, `representations`, `mutations`,
       `headers`, `config`, `domain_representations`) as auto-updatable views, so
       requests carrying `Accept-Profile: <area>` resolve to real exposed schemas.

  Connection parameters come from application env (`config/test.exs`).

      mix bier.fixtures.load
  """

  use Mix.Task

  # Pure table/data areas that are mirrored from `test` as auto-updatable views.
  # Function-heavy areas (rpc, openapi) are intentionally NOT mirrored here.
  @mirror_schemas ~w(operators ordering pagination representations mutations headers config domain_representations)

  @roles ~w(postgrest_test_anonymous postgrest_test_default_role postgrest_test_author)

  @impl Mix.Task
  def run(_args) do
    Application.ensure_all_started(:postgrex)
    Mix.Task.run("loadconfig")

    cfg = db_config()
    psql = psql_bin()
    fixtures = Path.expand("spec/conformance/fixtures.sql", File.cwd!())

    unless File.exists?(fixtures) do
      Mix.raise("Fixtures file not found: #{fixtures}")
    end

    Mix.shell().info(
      "Loading conformance fixtures into #{cfg[:database]} (#{cfg[:hostname]}:#{cfg[:port]})"
    )

    ensure_roles(psql, cfg)
    recreate_database(psql, cfg)
    load_fixtures(psql, cfg, fixtures)
    seed_corrections(psql, cfg)
    mirror_area_schemas(cfg)
    analyze(psql, cfg)

    Mix.shell().info("Done. Built area schemas: #{Enum.join(@mirror_schemas, ", ")}")
  end

  # --- steps ---------------------------------------------------------------

  defp ensure_roles(psql, cfg) do
    sql =
      @roles
      |> Enum.map(fn role ->
        "DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '#{role}') THEN CREATE ROLE #{role}; END IF; END $$;"
      end)
      |> Enum.join("\n")

    run_psql!(psql, cfg, "postgres", sql)
  end

  defp recreate_database(psql, cfg) do
    db = cfg[:database]

    run_psql!(psql, cfg, "postgres", ~s(DROP DATABASE IF EXISTS "#{db}";))
    run_psql!(psql, cfg, "postgres", ~s(CREATE DATABASE "#{db}";))
  end

  defp load_fixtures(psql, cfg, fixtures) do
    args =
      base_args(cfg, cfg[:database]) ++
        ["-v", "ON_ERROR_STOP=1", "-q", "-f", fixtures]

    {out, status} = System.cmd(psql, args, env: psql_env(cfg), stderr_to_stdout: true)

    if status != 0 do
      Mix.raise("psql failed loading fixtures (exit #{status}):\n#{out}")
    end
  end

  # Post-load seed corrections that align the consolidated fixtures with values
  # asserted by conformance cases but not seeded by the merged INSERTs. These are
  # confined to the `test` schema (mirrors pick them up automatically) and must
  # be idempotent.
  #
  #   * `test.complex_items."field-with_sep"` is asserted to equal the row id by
  #     the select cases (QuerySpec column-projection examples), but the merged
  #     INSERT omits the column so it defaults to 1. Set it to match the id.
  defp seed_corrections(psql, cfg) do
    sql = ~s(UPDATE test.complex_items SET "field-with_sep" = id;)
    run_psql!(psql, cfg, cfg[:database], sql)
  end

  # Refresh planner statistics across the whole database. The conformance
  # `count=planned`/`count=estimated` pagination cases assume analyzed tables
  # (their YAML preconditions run `ANALYZE`, but the frozen harness does not
  # execute preconditions), so we analyze here to make planner row estimates
  # match the small fixture tables (e.g. child_entities -> 6).
  defp analyze(psql, cfg) do
    run_psql!(psql, cfg, cfg[:database], "ANALYZE;")
  end

  defp mirror_area_schemas(cfg) do
    {:ok, conn} =
      Postgrex.start_link(
        hostname: cfg[:hostname],
        port: cfg[:port],
        database: cfg[:database],
        username: cfg[:username],
        password: cfg[:password]
      )

    try do
      # Relations in `test` to mirror (tables + views, anything selectable).
      %Postgrex.Result{rows: rows} =
        Postgrex.query!(
          conn,
          """
          SELECT c.relname
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE n.nspname = 'test'
            AND c.relkind = ANY(ARRAY['r','v','m','p','f'])
          ORDER BY c.relname
          """,
          []
        )

      relations = Enum.map(rows, fn [name] -> name end)

      # Single-composite-argument functions in `test` (computed columns /
      # computed relationships). For each area schema we recreate a thin wrapper
      # that takes the *area* relation's row type and delegates to the `test`
      # function (the row layouts are identical, so the cast is lossless). This
      # lets `order=<computed>` and computed embeddings resolve under the area's
      # Accept-Profile schema.
      computed_fns = query_computed_member_fns(conn)

      # Set-returning functions in `test` that return SETOF an exposed relation
      # (e.g. getitemrange, getallprojects). These back `/rpc/<fn>` calls under
      # an area's Accept-Profile, so we mirror them into each area schema as thin
      # wrappers that delegate to the `test` function but are typed against the
      # area's mirrored relation.
      setof_fns = query_setof_relation_fns(conn)

      for schema <- @mirror_schemas do
        Postgrex.query!(conn, ~s(DROP SCHEMA IF EXISTS "#{schema}" CASCADE), [])
        Postgrex.query!(conn, ~s(CREATE SCHEMA "#{schema}"), [])

        for rel <- relations do
          Postgrex.query!(
            conn,
            ~s(CREATE VIEW "#{schema}"."#{rel}" AS SELECT * FROM test."#{rel}"),
            []
          )
        end

        for fn_def <- setof_fns, fn_def.ret_relation in relations do
          Postgrex.query!(conn, mirror_setof_fn_ddl(schema, fn_def), [])
        end

        if schema == "representations", do: isolate_representations(conn)

        for %{name: fname, arg_rel: arg_rel, ret_type: ret_type} <- computed_fns,
            arg_rel in relations do
          dollar = "$bier$"
          body = ~s| SELECT "test"."#{fname}"(CAST(ROW(r.*) AS "test"."#{arg_rel}")) |

          ddl =
            ~s|CREATE FUNCTION "#{schema}"."#{fname}"(r "#{schema}"."#{arg_rel}") | <>
              ~s|RETURNS #{ret_type} LANGUAGE sql STABLE AS | <>
              dollar <> body <> dollar

          Postgrex.query!(conn, ddl, [])
        end
      end
    after
      GenServer.stop(conn)
    end
  end

  # The `representations` area exercises destructive writes (POST/PATCH/PUT/
  # DELETE). Because the area schemas mirror `test` as *auto-updatable views*,
  # those writes would pass straight through to the shared `test.*` tables and
  # corrupt the read-only areas (operators/ordering/pagination/...) running
  # concurrently in the same DB. To keep representations isolated, we replace the
  # mutable relations' views with independent *real tables* (copies of the
  # `test` data) carrying their own PK/FK/sequences. Reads/embeddings still work
  # (the FK is recreated); writes stay confined to the representations schema.
  #
  # Relations isolated: items, projects, clients, complex_items,
  # auto_incrementing_pk. `projects.client_id -> clients.id` is recreated so the
  # `select=...,clients(...)` embedding resolves within the schema.
  defp isolate_representations(conn) do
    tables = ~w(items projects clients complex_items auto_incrementing_pk)

    for t <- tables do
      Postgrex.query!(conn, ~s|DROP VIEW IF EXISTS "representations"."#{t}" CASCADE|, [])

      # INCLUDING ALL copies columns, defaults (incl. a fresh owned sequence for
      # serial/identity), not-null, and the primary key — independent of `test`.
      Postgrex.query!(
        conn,
        ~s|CREATE TABLE "representations"."#{t}" (LIKE "test"."#{t}" INCLUDING ALL)|,
        []
      )

      Postgrex.query!(
        conn,
        ~s|INSERT INTO "representations"."#{t}" SELECT * FROM "test"."#{t}"|,
        []
      )
    end

    # Case 1330 PUT /items?id=eq.10 must be an INSERT (201), so id=10 must be
    # absent from representations.items. No representations case requires id=10 to
    # pre-exist; the others target ids 1,2,3.
    Postgrex.query!(conn, ~s|DELETE FROM "representations"."items" WHERE id = 10|, [])

    # Recreate the projects -> clients foreign key for embedding resolution.
    Postgrex.query!(
      conn,
      ~s|ALTER TABLE "representations"."projects" ADD CONSTRAINT "client" | <>
        ~s|FOREIGN KEY ("client_id") REFERENCES "representations"."clients"("id")|,
      []
    )

    # `LIKE INCLUDING ALL` copies the serial DEFAULT verbatim, so it still points
    # at `test`'s sequence. Give representations.auto_incrementing_pk its own
    # sequence starting at 2 so the headers-only auto-pk insert (case 1305) is
    # deterministic and isolated (next nextval => 2). The frozen harness does not
    # run the case's ALTER SEQUENCE precondition, so we apply the equivalent here.
    Postgrex.query!(
      conn,
      ~s|CREATE SEQUENCE IF NOT EXISTS "representations"."auto_incrementing_pk_id_seq" START WITH 2|,
      []
    )

    Postgrex.query!(
      conn,
      ~s|ALTER TABLE "representations"."auto_incrementing_pk" | <>
        ~s|ALTER COLUMN "id" SET DEFAULT nextval('"representations"."auto_incrementing_pk_id_seq"')|,
      []
    )

    Postgrex.query!(
      conn,
      ~s|ALTER SEQUENCE "representations"."auto_incrementing_pk_id_seq" OWNED BY "representations"."auto_incrementing_pk"."id"|,
      []
    )

    Postgrex.query!(
      conn,
      ~s|SELECT setval('"representations"."auto_incrementing_pk_id_seq"', 2, false)|,
      []
    )
  end

  # Scalar single-composite-arg functions defined in `test` (computed columns).
  # Excludes set-returning and composite-returning functions (computed
  # relationships), which are handled differently and not needed by the
  # table/data area schemas.
  defp query_computed_member_fns(conn) do
    sql = """
    SELECT p.proname, arg_rel.relname, format_type(p.prorettype, NULL)
    FROM pg_proc p
    JOIN pg_namespace pn ON pn.oid = p.pronamespace
    JOIN pg_type arg_t ON arg_t.oid = p.proargtypes[0]
    JOIN pg_class arg_rel ON arg_rel.oid = arg_t.typrelid
    JOIN pg_namespace arg_n ON arg_n.oid = arg_rel.relnamespace
    JOIN pg_type ret_t ON ret_t.oid = p.prorettype
    WHERE pn.nspname = 'test'
      AND arg_n.nspname = 'test'
      AND p.pronargs = 1
      AND arg_t.typtype = 'c'
      AND NOT p.proretset
      AND ret_t.typtype <> 'c'
    """

    %Postgrex.Result{rows: rows} = Postgrex.query!(conn, sql, [])

    Enum.map(rows, fn [name, arg_rel, ret_type] ->
      %{name: name, arg_rel: arg_rel, ret_type: ret_type}
    end)
  end

  # Set-returning functions in `test` whose return type is SETOF an exposed
  # relation, with their ordered argument names/types. Overloads are rare in the
  # fixtures; we keep each (name, signature) pair.
  defp query_setof_relation_fns(conn) do
    sql = """
    SELECT
      p.proname,
      COALESCE(p.proargnames, ARRAY[]::text[]) AS arg_names,
      COALESCE((
        SELECT array_agg(format_type(t, NULL) ORDER BY ord)
        FROM unnest(p.proargtypes) WITH ORDINALITY AS u(t, ord)
      ), ARRAY[]::text[]) AS arg_types,
      ret_rel.relname AS ret_relation
    FROM pg_proc p
    JOIN pg_namespace pn ON pn.oid = p.pronamespace
    JOIN pg_type ret_t ON ret_t.oid = p.prorettype
    JOIN pg_class ret_rel ON ret_rel.oid = ret_t.typrelid
    JOIN pg_namespace ret_n ON ret_n.oid = ret_rel.relnamespace
    WHERE pn.nspname = 'test'
      AND p.proretset
      AND ret_t.typtype = 'c'
      AND ret_n.nspname = 'test'
      -- Only plain (table-style) functions: all-or-no named args and no
      -- composite-typed argument (those are computed relationships, mirrored
      -- separately as member wrappers, not as /rpc targets).
      AND p.pronargs = COALESCE(array_length(p.proargnames, 1), 0)
      AND NOT EXISTS (
        SELECT 1 FROM unnest(p.proargtypes) AS at(oid)
        JOIN pg_type t ON t.oid = at.oid
        WHERE t.typtype = 'c'
      )
    """

    %Postgrex.Result{rows: rows} = Postgrex.query!(conn, sql, [])

    Enum.map(rows, fn [name, arg_names, arg_types, ret_relation] ->
      args = Enum.zip(arg_names || [], arg_types || [])
      %{name: name, args: args, ret_relation: ret_relation}
    end)
  end

  # Build `CREATE FUNCTION <area>.<fn>(<args>) RETURNS SETOF <area>.<ret> ...`
  # delegating to `test.<fn>(<arg names>)`.
  defp mirror_setof_fn_ddl(schema, %{name: name, args: args, ret_relation: ret}) do
    arg_decls =
      args
      |> Enum.map(fn {n, t} -> ~s("#{n}" #{t}) end)
      |> Enum.join(", ")

    call_args =
      args
      |> Enum.map(fn {n, _t} -> ~s("#{n}") end)
      |> Enum.join(", ")

    dollar = "$bier$"
    body = ~s| SELECT * FROM "test"."#{name}"(#{call_args}) |

    ~s|CREATE FUNCTION "#{schema}"."#{name}"(#{arg_decls}) | <>
      ~s|RETURNS SETOF "#{schema}"."#{ret}" LANGUAGE sql STABLE AS | <>
      dollar <> body <> dollar
  end

  # --- helpers -------------------------------------------------------------

  defp db_config do
    [
      hostname: Application.get_env(:bier, :hostname, "localhost"),
      port: Application.get_env(:bier, :port, 5432),
      database: Application.get_env(:bier, :database, "bier_test"),
      username: Application.get_env(:bier, :username),
      password: Application.get_env(:bier, :password)
    ]
  end

  defp base_args(cfg, database) do
    args = ["-h", to_string(cfg[:hostname]), "-p", to_string(cfg[:port]), "-d", database]
    if cfg[:username], do: args ++ ["-U", to_string(cfg[:username])], else: args
  end

  defp psql_env(cfg) do
    if cfg[:password], do: [{"PGPASSWORD", to_string(cfg[:password])}], else: []
  end

  defp run_psql!(psql, cfg, database, sql) do
    args = base_args(cfg, database) ++ ["-v", "ON_ERROR_STOP=1", "-q", "-c", sql]
    {out, status} = System.cmd(psql, args, env: psql_env(cfg), stderr_to_stdout: true)

    if status != 0 do
      Mix.raise("psql failed (exit #{status}) running:\n#{sql}\n\n#{out}")
    end

    out
  end

  defp psql_bin do
    cond do
      bin = System.find_executable("psql") -> bin
      File.exists?("/opt/homebrew/opt/libpq/bin/psql") -> "/opt/homebrew/opt/libpq/bin/psql"
      true -> Mix.raise("psql not found on PATH or at /opt/homebrew/opt/libpq/bin/psql")
    end
  end
end
