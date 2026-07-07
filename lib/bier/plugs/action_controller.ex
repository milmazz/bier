defmodule Bier.Plugs.ActionController do
  @moduledoc """
  Request-time controller for the read + mutation pipeline.

  Every request reaches this plug via the catch-all router. It:

    1. resolves the target `{schema, relation}` from the path + `Accept-Profile`
       / `Content-Profile` (default schema = first of `db_schemas`),
    2. negotiates the response media type against the `Accept` header,
    3. parses the query string with `Bier.QueryParser`,
    4. builds and runs one parameterized JSON query via `Bier.QueryExecutor`,
    5. renders the negotiated format (JSON / CSV / singular object /
       nulls-stripped / EXPLAIN plan) with a `Content-Range`.

  Anything that is not a successful `Plug.Conn` falls through to
  `Bier.Plugs.FallbackController`, which emits the PostgREST error envelope.
  """

  @behaviour Plug

  import Plug.Conn

  alias Bier.MediaType
  alias Bier.Mutation
  alias Bier.Negotiation
  alias Bier.Pagination
  alias Bier.Plan
  alias Bier.Plugs.FallbackController
  alias Bier.QueryExecutor
  alias Bier.QueryParser
  alias Bier.Registry
  alias Bier.Response

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    name = conn.assigns.supervisor_name
    config = Registry.config(name)
    relations = Bier.SchemaCache.relations(name)

    case dispatch(conn, config, relations) do
      %Plug.Conn{} = conn -> conn
      error -> FallbackController.call(conn, error)
    end
  catch
    {:bad_request, _reason} -> FallbackController.call(conn, {:error, :unprocessable})
  end

  defp dispatch(conn, config, relations) do
    case conn.path_info do
      [] ->
        dispatch_root(conn, config)

      _ when conn.method == "OPTIONS" ->
        dispatch_options(conn, config, relations)

      ["rpc", fn_name] ->
        with {:ok, schema, content_profile} <- resolve_profile(conn, config),
             {:ok, conn} <- maybe_auth(conn, config, schema) do
          conn
          |> maybe_content_profile(content_profile)
          |> assign(:bier_target, {schema, fn_name})
          |> Bier.Rpc.dispatch(config, schema, fn_name)
        end

      _ ->
        dispatch_relation(conn, config, relations)
    end
  end

  # Resolve the per-request auth context (JWT verify + role + request GUCs) for
  # schemas that require it (the auth area). Stashes the context in
  # `conn.assigns.bier_auth` so the execution layer (reads/mutations/rpc) runs
  # its query inside a `SET LOCAL ROLE` + request.* GUC transaction. A JWT
  # verification failure short-circuits with the PostgREST error envelope.
  @doc false
  def maybe_auth(conn, config, schema) do
    if Bier.Auth.applicable?(schema) do
      case Bier.ServerTiming.measure(:jwt, fn -> Bier.Auth.resolve(conn, config) end) do
        {:ok, context} -> {:ok, assign(conn, :bier_auth, context)}
        {:error, _} = err -> err
      end
    else
      {:ok, conn}
    end
  end

  # ---- root (`/`) ----------------------------------------------------------

  # The root path serves the OpenAPI document for `application/openapi+json` /
  # `application/json` / `*/*`. The root now authenticates the request (resolving
  # the role from a bearer token, else the anon role) so the generated document
  # is filtered by that role's privileges. A token present with no jwt-secret
  # configured yields a 500 (PGRST300, the single line logged at log-level=error,
  # case 1764); an invalid token with a secret yields a 401.
  defp dispatch_root(conn, config) do
    if conn.method in ["GET", "HEAD"] do
      render_root(conn, config)
    else
      {:error, :method_not_allowed}
    end
  end

  defp render_root(conn, config) do
    case Negotiation.resolve(conn, [:openapi, :json]) do
      {:ok, media} ->
        conn = put_resp_header(conn, "content-type", MediaType.content_type(media))

        cond do
          # openapi-mode = disabled: the root metadata endpoint is off (PGRST126).
          config.openapi_mode == "disabled" ->
            {:error, :openapi_disabled}

          # db-root-spec: serve the named DB function's JSON verbatim.
          config.db_root_spec ->
            root_spec_body(conn, config)

          true ->
            generated_root_doc(conn, config)
        end

      {:error, _} = err ->
        err
    end
  end

  defp generated_root_doc(conn, config) do
    case Bier.Auth.resolve(conn, config) do
      {:ok, context} ->
        doc = build_openapi_document(config, context.role)
        root_doc_body(conn, Bier.json_library().encode!(doc))

      {:error, _} = err ->
        err
    end
  end

  # GET / returns the body with its byte length; HEAD / returns no body and no
  # Content-Length (mirroring PostgREST OpenApiSpec.hs:22-29).
  defp root_doc_body(%{method: "HEAD"} = conn, _body), do: send_resp(conn, 200, "")

  defp root_doc_body(conn, body) do
    conn
    |> put_resp_header("content-length", Integer.to_string(byte_size(body)))
    |> send_resp(200, body)
  end

  # db-root-spec: `GET /` invokes `<default-schema>.<root-spec>()` and returns its
  # JSON body instead of the generated document (PostgREST ApiRequest.hs:120-122).
  defp root_spec_body(%{method: "HEAD"} = conn, _config), do: send_resp(conn, 200, "")

  defp root_spec_body(conn, config) do
    [schema | _] = config.db_schemas

    fun =
      "#{Bier.QueryExecutor.quote_ident(schema)}.#{Bier.QueryExecutor.quote_ident(config.db_root_spec)}"

    Bier.ServerTiming.measure(:transaction, fn ->
      Postgrex.query(Registry.via(config.name, Postgrex), "SELECT (#{fun}())::text", [])
    end)
    |> case do
      {:ok, %Postgrex.Result{rows: [[body]]}} -> root_doc_body(conn, body)
      {:error, _} = err -> err
    end
  end

  # Builds the Swagger 2.0 document for the instance's default exposed schema,
  # honoring openapi-mode (follow-privileges filters by the request role's
  # privileges; ignore-privileges includes everything). Relations, functions,
  # and the schema comment come from the Bier.SchemaCache snapshot —
  # the same cache the request pipeline routes against — so the document never
  # advertises a relation the instance cannot serve. Only `privileges/3` runs
  # per request, because it depends on the request role.
  defp build_openapi_document(config, role) do
    schema = hd(config.db_schemas)
    cache = Bier.SchemaCache.get(config.name)

    relations =
      cache.relations
      |> Map.values()
      |> Enum.filter(&(&1.schema == schema))

    functions = Map.filter(cache.functions, fn {{s, _name}, _overloads} -> s == schema end)

    {relations, functions} = filter_by_mode(config, role, schema, relations, functions)

    Bier.OpenAPI.build(%{
      relations: relations,
      functions: function_inputs(functions),
      schema_comment: cache.schema_comment,
      security_active?: config.openapi_security_active,
      docs_version: "v14"
    })
  end

  defp filter_by_mode(config, role, schema, relations, functions) do
    case config.openapi_mode do
      "ignore-privileges" ->
        {relations, functions}

      _follow_privileges ->
        pg = Registry.via(config.name, Postgrex)
        privs = Bier.Introspection.privileges(pg, [schema], role)

        rels =
          for r <- relations,
              %{select?: true} = grants <- [privs.relations[{r.schema, r.name}]] do
            %{r | methods: granted_methods(r, grants)}
          end

        fns =
          functions
          |> Enum.filter(fn {{s, n}, _overloads} ->
            match?(%{execute?: true}, privs.functions[{s, n}])
          end)
          |> Map.new()

        {rels, fns}
    end
  end

  # follow-privileges trims a table's advertised write methods to what the
  # role is granted (PostgREST OpenApiSpec). Views stay GET-only (kind default).
  defp granted_methods(%{kind: :table}, grants) do
    [:get] ++
      for {method, granted?} <- [
            post: grants.insert?,
            patch: grants.update?,
            delete: grants.delete?
          ],
          granted?,
          do: method
  end

  defp granted_methods(_view, _grants), do: nil

  # Flatten the introspection functions map (keyed by {schema,name} => [overloads])
  # into the builder's function-input list.
  defp function_inputs(functions) do
    functions
    |> Enum.flat_map(fn {_key, overloads} -> overloads end)
    |> Enum.map(fn ov ->
      %{name: ov.name, comment: ov.comment, volatility: ov.volatility, in_params: ov.args}
    end)
  end

  # OPTIONS on a relation: PostgREST answers 200 with an empty body and an
  # `Allow` header of the supported methods (OptionsSpec). A writeable
  # table/auto-updatable view advertises the full mutating set; the response
  # carries no Content-Type. A request to an unknown relation still answers 200
  # (preflight/observability OPTIONS cases) without an Allow header.
  @writeable_allow "OPTIONS,GET,HEAD,POST,PUT,PATCH,DELETE"

  defp dispatch_options(conn, config, relations) do
    conn
    |> maybe_allow_header(config, relations)
    |> put_resp_header("content-length", "0")
    |> send_resp(200, "")
  end

  defp maybe_allow_header(conn, config, relations) do
    with {:ok, schema, _profile} <- resolve_profile(conn, config),
         {:ok, _relation} <- resolve_relation(conn, schema, relations) do
      put_resp_header(conn, "allow", @writeable_allow)
    else
      _ -> conn
    end
  end

  defp dispatch_relation(conn, config, relations) do
    with {:ok, schema, content_profile} <- resolve_profile(conn, config),
         {:ok, conn} <- maybe_auth(conn, config, schema),
         conn = maybe_content_profile(conn, content_profile),
         :ok <- reject_openapi_media(conn),
         {:ok, relation} <- resolve_relation(conn, schema, relations) do
      # Tag the resolved target so the observability span (`:bier_target`) can
      # report schema/relation on `[:bier, :request, :stop]`.
      conn = assign(conn, :bier_target, {relation.schema, relation.name})
      handle(conn.method, conn, config, relation)
    end
  end

  # The `application/openapi+json` producer is only available at the root path
  # (the OpenAPI document). PostgREST answers 406 for an openapi Accept on any
  # non-root path, regardless of whether the relation exists (OpenApiSpec.hs:31).
  # This is checked before relation resolution so an openapi request to a missing
  # relation is 406 (not 404). A request that also offers an acceptable producer
  # (e.g. `*/*` or `application/json`) ahead of openapi is honored normally.
  defp reject_openapi_media(conn) do
    accepts =
      conn
      |> Negotiation.accept()
      |> MediaType.parse_accept()

    if openapi_unacceptable?(accepts) do
      {:error, {:not_acceptable, Negotiation.accept(conn) || "*/*"}}
    else
      :ok
    end
  end

  # True when openapi is requested and no preceding entry is a generally-available
  # relation producer (`:json`, `:csv`, …) or a wildcard. Client order wins, so an
  # acceptable producer listed before openapi makes the request acceptable.
  defp openapi_unacceptable?(accepts) do
    Enum.reduce_while(accepts, false, fn mt, _ ->
      cond do
        mt.symbol == :openapi ->
          {:halt, true}

        mt.symbol in [:any, :json, :csv, :geojson, :octet, :text, :tsv, :singular, :array_strip] ->
          {:halt, false}

        true ->
          {:cont, false}
      end
    end)
  end

  # Echo the resolved schema in Content-Profile when a profile schema applies.
  # Set early so every downstream render (read/mutation/rpc) carries it.
  defp maybe_content_profile(conn, nil), do: conn

  defp maybe_content_profile(conn, profile),
    do: put_resp_header(conn, "content-profile", profile)

  # Content-Location is the canonical request URL: the path plus the query
  # parameters re-emitted in alphabetical (key) order. With no params the path is
  # emitted alone (no trailing `?`). PostgREST renders this on table GET reads
  # (QuerySpec L1234-1246). Values are kept verbatim (the conformance harness
  # compares the raw header string).
  defp put_content_location(conn) do
    location =
      case canonical_query(conn.query_string) do
        "" -> conn.request_path
        qs -> conn.request_path <> "?" <> qs
      end

    put_resp_header(conn, "content-location", location)
  end

  defp canonical_query(""), do: ""

  defp canonical_query(query_string) do
    query_string
    |> URI.query_decoder()
    |> Enum.sort_by(fn {k, _v} -> k end)
    |> Enum.map_join("&", fn
      {k, ""} -> k
      {k, v} -> k <> "=" <> v
    end)
  end

  # ---- handlers (relations) ------------------------------------------------

  defp handle(method, conn, config, relation) when method in ["GET", "HEAD"] do
    conn = put_content_location(conn)

    case Bier.CustomMedia.maybe_relation(conn, config, relation) do
      :no_handler ->
        with {:ok, media} <- Negotiation.resolve(conn, relation_producers(config)) do
          handle_get(conn, config, relation, media)
        end

      result ->
        result
    end
  end

  defp handle(method, conn, config, relation) when method in ["POST", "PATCH", "PUT", "DELETE"] do
    with {:ok, media} <- Negotiation.resolve(conn, relation_producers(config)) do
      Mutation.handle(conn, config, relation, media)
    end
  end

  defp handle(_method, _conn, _config, _relation), do: {:error, :method_not_allowed}

  defp handle_get(conn, config, relation, %MediaType{symbol: :plan} = media) do
    pool = Bier.Registry.via(config.name, Postgrex)

    with {:ok, plan} <- parse(conn, config) do
      Plan.explain(conn, pool, relation, plan, media)
    end
  end

  defp handle_get(conn, config, relation, media) do
    pool = Bier.Registry.via(config.name, Postgrex)
    relations = Bier.SchemaCache.relations(config.name)
    count_mode = Pagination.count_mode(conn)
    config = effective_config(config, relation)

    with {:ok, prefs} <- Bier.Preferences.parse_read(conn, pool),
         {:ok, plan} <- parse(conn, config),
         {:ok, %{body: body, count: count}} <-
           QueryExecutor.run(pool, relation, plan, relations,
             count_mode: count_mode,
             max_rows: config.db_max_rows,
             timezone: prefs.timezone,
             auth: auth_setup(conn, config)
           ) do
      conn
      |> put_preference_applied(prefs.applied)
      |> Response.render(body, count, plan, count_mode, media,
        columns: csv_columns(plan, relation)
      )
    end
  end

  # The auth-context tuple `{context, config}` threaded into the execution layer,
  # or nil when the request schema does not require role-switching/GUCs.
  @doc false
  def auth_setup(conn, config) do
    case conn.assigns[:bier_auth] do
      nil -> nil
      context -> {context, config}
    end
  end

  defp put_preference_applied(conn, []), do: conn

  defp put_preference_applied(conn, tokens),
    do: put_resp_header(conn, "preference-applied", Enum.join(tokens, ", "))

  # ---- target resolution ---------------------------------------------------

  # Area labels the conformance harness turns into a profile header but which are
  # NOT themselves a selectable multi-schema; they alias the default profile
  # schema (`db_profile_default`). `headers`/`multi` carry the MultipleSchemaSpec
  # cases whose default schema is v1.
  @profile_aliases ~w(headers multi)

  # Resolve the target schema for relation/RPC lookup AND the schema name to echo
  # in `Content-Profile`. Returns `{:ok, schema, content_profile}` where
  # `content_profile` is nil when no profile should be echoed.
  @doc false
  def resolve_profile(conn, config) do
    [default | _] = config.db_schemas

    profile = request_profile(conn)
    aliases = config.db_schema_aliases || %{}

    cond do
      # A configured profile-label alias (e.g. `unicode` -> `تست`): resolve to the
      # mapped real schema. No Content-Profile is echoed (these cases don't
      # assert one and the schema name is exotic).
      is_binary(profile) and Map.has_key?(aliases, profile) ->
        {:ok, Map.fetch!(aliases, profile), nil}

      # No explicit profile, or an area-label alias: resolve in the default
      # schema. When a multi-schema default is configured (db_profile_default),
      # relations live in that area's own schema (e.g. `headers`) but the echoed
      # Content-Profile names the logical default (e.g. `v1`).
      is_nil(profile) or profile in @profile_aliases ->
        {:ok, default_profile_schema(profile, config, default), config.db_profile_default}

      # An explicit, exposed schema: resolve there and echo it verbatim.
      profile in config.db_schemas ->
        {:ok, profile, content_profile_for(profile, config)}

      true ->
        {:error, {:invalid_schema, profile, exposed_profiles(config)}}
    end
  end

  # An alias label that is itself an exposed schema (e.g. `headers`, whose
  # mirror schema physically holds the relations) resolves to that schema.
  # A pure label like `multi` is not a real schema — its data lives in the
  # default profile schema (e.g. `v1`), so resolve there.
  defp default_profile_schema(nil, _config, default), do: default

  defp default_profile_schema(profile, config, default) do
    if profile in config.db_schemas, do: profile, else: config.db_profile_default || default
  end

  defp request_profile(conn) do
    case conn.method do
      m when m in ["GET", "HEAD"] ->
        header(conn, "accept-profile")

      _ ->
        # Writes target the Content-Profile schema; fall back to Accept-Profile
        # so a write whose response schema is pinned (the conformance harness
        # sends only Accept-Profile) still resolves to that schema.
        header(conn, "content-profile") || header(conn, "accept-profile")
    end
  end

  # Echo Content-Profile for an explicit profile only when multi-schema profile
  # routing is configured (the MultipleSchemaSpec cases). Other areas do not
  # assert Content-Profile, and PostgREST omits it when a single schema is
  # exposed, so we only echo for the configured profile schemas.
  defp content_profile_for(profile, %{db_profile_schemas: schemas}) when is_list(schemas) do
    if profile in schemas, do: profile, else: nil
  end

  defp content_profile_for(_profile, _config), do: nil

  defp exposed_profiles(%{db_profile_schemas: schemas}) when is_list(schemas), do: schemas
  defp exposed_profiles(_config), do: nil

  # Area-mirror schemas are auto-updatable views over the base `test` schema
  # (see docs/CONFORMANCE_IMPL.md §2.2). PostgREST's own cases were authored
  # against the base `test` schema, so a not-found error must report `test.<rel>`
  # even though the request resolved through the mirror label.
  @mirror_schemas ~w(operators ordering pagination representations mutations config domain_representations)

  defp resolve_relation(conn, schema, relations) do
    case conn.path_info do
      [segment] ->
        relation = decode_segment(segment)

        case Map.fetch(relations, {schema, relation}) do
          {:ok, rel} -> {:ok, rel}
          :error -> {:error, {:unknown_relation, reported_schema(schema), relation}}
        end

      _ ->
        {:error, :invalid_path}
    end
  end

  defp reported_schema(schema) when schema in @mirror_schemas, do: "test"
  defp reported_schema(schema), do: schema

  # ---- query plan ----------------------------------------------------------

  @doc false
  def parse(conn, config) do
    Bier.ServerTiming.measure(:parse, fn ->
      with {:ok, plan} <- QueryParser.parse_request(conn.query_string) do
        Pagination.apply_window(plan, conn, config.db_max_rows)
      end
    end)
  end

  # Resolve the effective config for a relation read. PostgREST has a single
  # `db-max-rows`, but the conformance suite's `config` area needs a per-schema
  # cap (db-max-rows=2 only for the `config` schema) on the shared instance, so
  # a per-schema override replaces the global value when the resolved schema
  # matches `db_max_rows_by_schema`.
  defp effective_config(config, %{schema: schema}) do
    case Map.fetch(config.db_max_rows_by_schema || %{}, schema) do
      {:ok, max} -> %{config | db_max_rows: max}
      :error -> config
    end
  end

  defp effective_config(config, _relation), do: config

  # The available producers for a relation/RPC result set. Plan is gated on
  # db-plan-enabled. octet-stream and geo+json are not generally available
  # (they require specific handlers) and are negotiated only where supported.
  @doc false
  def relation_producers(config) do
    base = [:json, :csv, :singular, :array_strip]
    if config.db_plan_enabled, do: base ++ [:plan], else: base
  end

  # CSV column order: explicit select fields, else the relation's columns.
  @doc false
  def csv_columns(plan, relation) do
    case plan.select do
      [:star] -> Enum.map(relation.columns, & &1.name)
      fields -> select_field_names(fields)
    end
  end

  defp select_field_names(fields) do
    fields
    |> Enum.flat_map(fn
      %{kind: :star} -> []
      %{alias: al, column: col, json_path: jp} -> [QueryExecutor.json_output_name(al || col, jp)]
      _ -> []
    end)
  end

  defp header(conn, name) do
    case get_req_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  # Percent-decode a path segment (PostgREST decodes the relation/RPC name from
  # the URL path, so e.g. `%D9%85...` resolves to the unicode relation موارد).
  # The adapter does not decode `conn.path_info`, so do it here. Decoding is a
  # no-op for unencoded ASCII names.
  defp decode_segment(segment), do: URI.decode(segment)
end
