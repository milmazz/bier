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
  # Function-heavy areas (rpc, openapi, headers) are intentionally NOT mirrored
  # here. `headers` is function- and trigger-heavy (GUC response.headers /
  # response.status) and additionally needs multi-schema profile routing
  # (v1/v2/SPECIAL), so it is built by `load_headers_schema/2` from its own
  # `headers.sql` fragment rather than as a view-mirror of `test`.
  @mirror_schemas ~w(operators ordering pagination representations mutations config domain_representations)

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
    load_rpc_schema(psql, cfg)
    load_headers_schema(psql, cfg)
    load_auth_schema(psql, cfg)
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

  # The `rpc` area is function-heavy: views cannot mirror functions (overloads,
  # OUT/INOUT/VARIADIC params, defaults, volatility). Per docs/CONFORMANCE_IMPL.md
  # §2.2 option 2, we re-load the self-contained `rpc` fragment into a real `rpc`
  # schema by remapping its `test`-qualified DDL to `rpc`. The fragment only
  # references `test.*` objects and `public`, so a word-boundary rewrite of
  # `\btest\b` -> `rpc` is lossless (no string literal contains the token `test`).
  defp load_rpc_schema(psql, cfg) do
    fragment = Path.expand("spec/conformance/fixtures/rpc.sql", File.cwd!())

    unless File.exists?(fragment) do
      Mix.raise("RPC fixture fragment not found: #{fragment}")
    end

    sql =
      fragment
      |> File.read!()
      |> String.replace(~r/\btest\b/, "rpc")

    # Drop first so the load is idempotent, then create the remapped objects and
    # grant the anon role EXECUTE/SELECT so anonymous /rpc calls succeed.
    full =
      ~s(DROP SCHEMA IF EXISTS rpc CASCADE;\n) <>
        sql <>
        "\n" <>
        ~s(GRANT USAGE ON SCHEMA rpc TO postgrest_test_anonymous;\n) <>
        ~s(GRANT SELECT ON ALL TABLES IN SCHEMA rpc TO postgrest_test_anonymous;\n) <>
        ~s(GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA rpc TO postgrest_test_anonymous;\n)

    run_psql!(psql, cfg, cfg[:database], full)
  end

  # The `headers` area is function- and trigger-heavy and additionally exercises
  # multi-schema profile routing. We build a real `headers` schema from the
  # self-contained `spec/conformance/fixtures/headers.sql` fragment:
  #
  #   * the `test`-schema portion (tables + the `stuff` INSTEAD OF-trigger view +
  #     the GUC response.headers / response.status RPC functions) is loaded into
  #     a real `headers` schema by remapping `\btest\b` -> `headers` and the
  #     fragment's `private` schema -> `headers_private` (so nothing collides with
  #     the consolidated `private.stuff`).
  #   * the multi-schema (v1/v2/SPECIAL) tables already exist from the
  #     consolidated `fixtures.sql`, so the fragment's own multi-schema section is
  #     dropped. Instead we expose `parents`/`children`/`names` inside the
  #     `headers` schema as auto-updatable views over `v1` (the default profile),
  #     so a default-profile (`Accept-Profile: headers`) read of `/parents`
  #     resolves to v1's rows while still living in the `headers` schema.
  #
  # `db_profile_default` (v1) drives the Content-Profile echo for the default
  # profile; explicit `Accept-Profile: v2|SPECIAL...` reads resolve directly in
  # those real schemas (which carry their own data).
  defp load_headers_schema(psql, cfg) do
    fragment = Path.expand("spec/conformance/fixtures/headers.sql", File.cwd!())

    unless File.exists?(fragment) do
      Mix.raise("headers fixture fragment not found: #{fragment}")
    end

    raw = File.read!(fragment)

    # Keep only the test/private portion (everything before the multi-schema
    # section). That marker is stable in the fragment.
    [test_portion | _] = String.split(raw, "-- Multi-schema tables", parts: 2)

    sql =
      test_portion
      # The fragment qualifies every object with its schema, so word-boundary
      # rewrites are lossless (no string literal contains a bare `test`/`private`
      # token; header values use `X-Test`/`Test`, which differ in case).
      |> String.replace(~r/\btest\b/, "headers")
      |> String.replace(~r/\bprivate\b/, "headers_private")

    # parents/children/names are exposed in `headers` as views over the
    # default profile schema v1 so a default-profile read resolves to v1.
    full =
      ~s(DROP SCHEMA IF EXISTS headers CASCADE;\n) <>
        ~s(DROP SCHEMA IF EXISTS headers_private CASCADE;\n) <>
        ~s(CREATE SCHEMA headers;\n) <>
        sql <>
        "\n" <>
        ~s(CREATE VIEW headers.parents AS SELECT * FROM v1.parents;\n) <>
        ~s(CREATE VIEW headers.children AS SELECT * FROM v1.children;\n) <>
        ~s(GRANT USAGE ON SCHEMA headers TO postgrest_test_anonymous;\n) <>
        ~s(GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA headers TO postgrest_test_anonymous;\n) <>
        ~s(GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA headers TO postgrest_test_anonymous;\n)

    run_psql!(psql, cfg, cfg[:database], full)
  end

  # The `auth` area mirrors `test` into a real `auth` schema that PRESERVES the
  # restrictive privileges the auth cases depend on. Unlike the read-only area
  # mirrors, the auth views are `security_invoker` so the base-table grants on
  # `test.*` apply under SET ROLE, and the views themselves carry grants matching
  # the base tables:
  #
  #   * authors_only  — grant ALL to postgrest_test_author only (anon -> 42501)
  #   * private_table — no grants (everyone but superuser -> 42501)
  #   * items         — SELECT to anon
  #   * has_count_column — SELECT, INSERT to anon
  #
  # The auth functions are thin wrappers delegating to their `test.*` originals
  # (so SECURITY DEFINER / GUC-reading / SET-LOCAL-ROLE behavior is preserved),
  # with EXECUTE grants matching the originals: privileged_hello is revoked from
  # PUBLIC and granted to author; the rest stay PUBLIC.
  defp load_auth_schema(psql, cfg) do
    sql = """
    DROP SCHEMA IF EXISTS auth CASCADE;
    CREATE SCHEMA auth;
    GRANT USAGE ON SCHEMA auth TO postgrest_test_anonymous, postgrest_test_default_role, postgrest_test_author;

    -- Tables as security_invoker views over test.* so base-table grants apply
    -- under SET ROLE. View grants mirror the base-table grants.
    CREATE VIEW auth.authors_only WITH (security_invoker = true) AS SELECT * FROM test.authors_only;
    CREATE VIEW auth.private_table WITH (security_invoker = true) AS SELECT * FROM test.private_table;
    CREATE VIEW auth.items WITH (security_invoker = true) AS SELECT * FROM test.items;
    CREATE VIEW auth.has_count_column WITH (security_invoker = true) AS SELECT * FROM test.has_count_column;

    -- The views are granted to all roles so the view-level privilege check
    -- passes; security_invoker then forwards to the BASE table, where the real
    -- grant gap on test.* produces the 42501 "...for table <name>" message the
    -- cases assert (a view-level denial would say "...for view <name>").
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE auth.authors_only, auth.private_table, auth.items, auth.has_count_column TO postgrest_test_anonymous, postgrest_test_default_role, postgrest_test_author;

    -- Functions: thin wrappers delegating to the test.* originals.
    CREATE FUNCTION auth.get_current_user() RETURNS text
      LANGUAGE sql STABLE AS $$ SELECT test.get_current_user(); $$;

    CREATE FUNCTION auth.switch_role() RETURNS void
      LANGUAGE plpgsql AS $$ BEGIN PERFORM test.switch_role(); END $$;

    CREATE FUNCTION auth.reveal_big_jwt() RETURNS TABLE (
      iss text, sub text, exp bigint, nbf bigint, iat bigint, jti text,
      "http://postgrest.com/foo" boolean
    ) LANGUAGE sql STABLE AS $$ SELECT * FROM test.reveal_big_jwt(); $$;

    CREATE FUNCTION auth.get_guc_value(name text) RETURNS text
      LANGUAGE sql AS $$ SELECT test.get_guc_value(name); $$;

    CREATE FUNCTION auth.get_guc_value(prefix text, name text) RETURNS text
      LANGUAGE sql AS $$ SELECT test.get_guc_value(prefix, name); $$;

    CREATE FUNCTION auth.privileged_hello(name text) RETURNS text
      LANGUAGE sql AS $$ SELECT test.privileged_hello(name); $$;

    CREATE FUNCTION auth.login(id text, pass text) RETURNS public.jwt_token
      LANGUAGE sql STABLE AS $$ SELECT test.login(id, pass); $$;

    CREATE FUNCTION auth.jwt_test() RETURNS public.jwt_token
      LANGUAGE sql AS $$ SELECT test.jwt_test(); $$;

    -- EXECUTE grants: privileged_hello author-only; switch_role runs as the
    -- pre-request hook so the connecting superuser must reach it (PUBLIC is fine).
    REVOKE EXECUTE ON FUNCTION auth.privileged_hello(text) FROM PUBLIC;
    GRANT EXECUTE ON FUNCTION auth.privileged_hello(text) TO postgrest_test_author;
    """

    run_psql!(psql, cfg, cfg[:database], sql)
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
        if schema == "mutations", do: isolate_mutations(conn)

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

  # The `mutations` area exercises destructive writes (POST/PATCH/PUT/DELETE).
  # Like `representations`, the area schemas mirror `test` as auto-updatable
  # views, so writes would pass through to the shared `test.*` base tables. Even
  # though the request pipeline rolls every transaction back (db-tx-end =
  # rollback) so the DB stays pristine, two of the mutation targets need a seed
  # state that DIFFERS from `test.*`:
  #
  #   * `complex_items` — case 1361 (missing=default) requires the column DEFAULT
  #     `field-with_sep = 1` to be visible to introspection. A VIEW does not carry
  #     the underlying column default, so a real table (LIKE ... INCLUDING ALL)
  #     is needed to expose it.
  #   * `articles` — case 1366 PATCHes id=1 and asserts owner =
  #     'postgrest_test_anonymous' (the column DEFAULT), but `test.articles`'s
  #     operators seed has owner='diogo'. The case's precondition (not run by the
  #     frozen harness) would reset the row; we seed the isolated table to the
  #     post-precondition state instead.
  #
  # The other writable targets (items, tiobe_pls, simple_pk, no_pk,
  # single_unique, compound_unique, safe_update_items, safe_delete_items) already
  # match each case's expected starting state in `test.*`, but we isolate them as
  # independent real tables too so their column defaults/sequences are exposed and
  # the area is fully self-contained.
  defp isolate_mutations(conn) do
    tables =
      ~w(items articles complex_items tiobe_pls simple_pk no_pk single_unique
         compound_unique safe_update_items safe_delete_items)

    for t <- tables do
      Postgrex.query!(conn, ~s|DROP VIEW IF EXISTS "mutations"."#{t}" CASCADE|, [])

      Postgrex.query!(
        conn,
        ~s|CREATE TABLE "mutations"."#{t}" (LIKE "test"."#{t}" INCLUDING ALL)|,
        []
      )

      Postgrex.query!(
        conn,
        ~s|INSERT INTO "mutations"."#{t}" SELECT * FROM "test"."#{t}"|,
        []
      )
    end

    # `complex_items."field-with_sep"` is rewritten by seed_corrections to equal
    # the row id in `test`. The mutations cases (1361, 1371) want the original
    # per-column DEFAULT (1) preserved and the seed rows intact, so reset the copy
    # to the column DEFAULT for existing rows.
    Postgrex.query!(conn, ~s|UPDATE "mutations"."complex_items" SET "field-with_sep" = 1|, [])

    # Case 1366 PATCHes articles id=1 and asserts owner = 'postgrest_test_anonymous'
    # (the precondition resets the row, dropping operators' 'diogo' seed). Replace
    # the seed with the post-precondition state: only id=1, owner defaulted.
    Postgrex.query!(conn, ~s|DELETE FROM "mutations"."articles"|, [])

    Postgrex.query!(
      conn,
      ~s|INSERT INTO "mutations"."articles" (id, body) VALUES (1, 'orig')|,
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
    # Load under UTC so timestamps inserted WITHOUT an explicit offset (e.g. the
    # domain-representation seed `'2017-12-14 01:02:30'::timestamptz`) become the
    # same absolute instants as PostgREST's reference DB, which runs in UTC. The
    # request pipeline also pins the session timezone to UTC (see Bier.postgrex_opts/1).
    base = [{"PGTZ", "UTC"}]
    if cfg[:password], do: [{"PGPASSWORD", to_string(cfg[:password])} | base], else: base
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
