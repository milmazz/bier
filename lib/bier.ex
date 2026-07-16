defmodule Bier do
  @moduledoc """
  Public entry point for a Bier instance.

  `Bier` is a `Supervisor` that the host application starts to spin up one
  named instance — its own validated configuration, its own Bandit web server,
  and its own router built on the fly from database introspection. Multiple
  instances can coexist in the same node by passing distinct `:name` values.

  ## Usage

  Add a `Bier` child to your application's supervision tree:

      children = [
        {Bier, name: MyApp.Bier, router: [port: 4040, scheme: :http]}
      ]

  Pass `admin_server_port:` to also expose the `/live` and `/ready` health
  endpoints on a separate listener (it must differ from `router[:port]`):

      children = [
        {Bier,
         name: MyApp.Bier, router: [port: 4040, scheme: :http], admin_server_port: 4041}
      ]

  See `start_link/1` for the full list of options.

  Per-instance processes are registered through `Bier.Registry`.
  """

  use Supervisor

  alias Bier.Registry

  @type name :: term()

  # The option schema is built at runtime so that DB defaults are sourced from
  # application env. This matters because `Bier.ConformanceServer` starts an
  # instance passing only `:name` and `:router`; every DB/PostgREST setting must
  # therefore fall back to `config/*.exs` (application env), not a compile-time
  # literal.
  @doc false
  def schema do
    [
      name: [
        type: :atom,
        required: false,
        default: __MODULE__,
        doc: "Used for the supervisor name registration."
      ],
      router: [
        type: :non_empty_keyword_list,
        required: false,
        subsection: "REST endpoint options",
        # TODO: Change the scheme to HTTPS
        default: [port: 4040, scheme: :http],
        doc: """
        Options needed for the Web endpoint, which under the hood is powered by
        `Bandit`.
        """,
        keys: [
          port: [
            type: :pos_integer,
            required: true,
            default: 4040,
            doc: "The TCP port to bind the web server."
          ],
          scheme: [
            type: {:in, [:http, :https]},
            required: true,
            # TODO: Change this to HTTPS
            default: :http,
            doc: "Either `:https` or `:http`."
          ]
        ]
      ],
      hostname: [
        type: :string,
        default: env(:hostname, "localhost"),
        doc: "Postgres host for the per-instance connection pool."
      ],
      port: [
        type: :pos_integer,
        default: env(:port, 5432),
        doc: "Postgres TCP port."
      ],
      database: [
        type: :string,
        default: env(:database, "bier"),
        doc: "Postgres database name."
      ],
      username: [
        type: {:or, [:string, nil]},
        default: env(:username, nil),
        doc: "Postgres username."
      ],
      password: [
        type: {:or, [:string, nil]},
        default: env(:password, nil),
        doc: "Postgres password."
      ],
      ssl: [
        type: :boolean,
        default: env(:ssl, false),
        doc: """
        Whether the Postgrex pool connects over TLS (what PostgREST's `db-uri`
        selects via `sslmode=require`/`verify-*`). Defaults to `false`.
        """
      ],
      pool_size: [
        type: :pos_integer,
        default: env(:pool_size, 10),
        doc: "Size of the per-instance Postgrex connection pool (PostgREST db-pool)."
      ],
      db_pool_max_idletime: [
        type: {:or, [:pos_integer, nil]},
        default: env(:db_pool_max_idletime, nil),
        doc: """
        Idle-connection maintenance interval in seconds (PostgREST
        db-pool-max-idletime, deprecated alias db-pool-timeout). Mapped onto
        DBConnection's `:idle_interval` — the knob governing what happens to
        pool connections idle for this long (DBConnection pings them; PostgREST
        closes them). When nil (the default) the driver default applies.
        """
      ],
      server_host: [
        type: :string,
        default: env(:server_host, "!4"),
        doc: """
        Bind address for the HTTP listener(s) (PostgREST server-host, a Warp
        `HostPreference`): `!4`/`*`/`*4` bind any IPv4 interface, `!6`/`*6` any
        IPv6 one, anything else an IP literal or resolvable host name. The
        default `!4` matches both PostgREST and Bier's previous
        all-IPv4-interfaces behavior.
        """
      ],
      server_unix_socket: [
        type: {:or, [:string, nil]},
        default: env(:server_unix_socket, nil),
        doc: """
        Path of a Unix domain socket to serve the API on instead of a TCP port
        (PostgREST server-unix-socket). When set, `router[:port]` and
        `server_host` are ignored for the main listener; a stale socket file at
        the path is removed before binding.
        """
      ],
      server_unix_socket_mode: [
        type: :string,
        default: env(:server_unix_socket_mode, "660"),
        doc: """
        Octal file mode applied to the Unix socket file after binding
        (PostgREST server-unix-socket-mode). Must parse as octal between 600
        and 777; validated at boot even when no socket path is configured,
        matching PostgREST.
        """
      ],
      db_schemas: [
        type: {:list, :string},
        default: env(:db_schemas, ["public"]),
        doc: "Ordered list of exposed schemas; the first is the default schema."
      ],
      db_profile_default: [
        type: {:or, [:string, nil]},
        default: env(:db_profile_default, nil),
        doc: """
        Schema that a default-profile request (no Accept-Profile/Content-Profile,
        or the area-label aliases `headers`/`multi`) resolves to and echoes in
        `Content-Profile`. Used by the multi-schema (MultipleSchemaSpec) cases,
        where the default schema is `v1`. When nil, the first of `db_schemas` is
        the default and no Content-Profile is echoed.
        """
      ],
      db_profile_schemas: [
        type: {:or, [{:list, :string}, nil]},
        default: env(:db_profile_schemas, nil),
        doc: """
        Exposure-ordered list of schemas selectable via Accept-Profile/
        Content-Profile, reported verbatim in the PGRST106 hint when an unknown
        profile is requested. When nil, profile routing falls back to
        `db_schemas` and the PGRST106 error carries no hint.
        """
      ],
      db_schema_aliases: [
        type: {:map, :string, :string},
        default: env(:db_schema_aliases, %{}),
        doc: """
        Map of profile-label aliases to the real schema they resolve to. The
        conformance harness turns a case's `schema:` label into an
        `Accept-Profile`/`Content-Profile` header, but some labels (e.g.
        `unicode`) are not themselves an exposed Postgres schema — their data
        lives in a differently named schema (e.g. the unicode schema `تست`).
        A label present here resolves to its mapped schema for relation/RPC
        lookup.
        """
      ],
      db_anon_role: [
        type: {:or, [:string, nil]},
        default: env(:db_anon_role, nil),
        doc: "Role assumed for anonymous (unauthenticated) requests."
      ],
      db_extra_search_path: [
        type: {:list, :string},
        default: env(:db_extra_search_path, ["public"]),
        doc: "Extra schemas appended to the search path."
      ],
      db_max_rows: [
        type: {:or, [:pos_integer, nil]},
        default: env(:db_max_rows, nil),
        doc: "Maximum number of rows returned per request (PostgREST db-max-rows)."
      ],
      db_max_rows_by_schema: [
        type: {:map, :string, :pos_integer},
        default: env(:db_max_rows_by_schema, %{}),
        doc: """
        Per-schema override of `db-max-rows`, keyed by resolved schema name.
        PostgREST exposes a single `db-max-rows`, but the conformance suite boots
        ONE shared instance whose `config`-area cases require `db-max-rows=2`
        while every other area needs the rows uncapped. A request whose resolved
        schema is a key here uses that cap instead of the global `db_max_rows`.
        """
      ],
      db_plan_enabled: [
        type: :boolean,
        default: env(:db_plan_enabled, false),
        doc: "Enables the application/vnd.pgrst.plan media type (PostgREST db-plan-enabled)."
      ],
      db_tx_end: [
        type: {:in, [:commit, :rollback]},
        default: env(:db_tx_end, :commit),
        doc: """
        How a request's transaction ends (PostgREST db-tx-end). `:commit`
        persists writes (production default). `:rollback` rolls every request's
        transaction back after the response is computed — the response is
        identical, but nothing persists. Used by the conformance suite so the
        shared fixture DB stays pristine under `async: true`.
        """
      ],
      db_safe_update_tables: [
        type: {:list, :string},
        default: env(:db_safe_update_tables, []),
        doc: """
        Relation names for which a filterless UPDATE/DELETE raises SQLSTATE 21000
        (PostgREST's pg-safeupdate integration). Emulated per request rather than
        by loading the extension.
        """
      ],
      db_pre_request: [
        type: {:or, [:string, nil]},
        default: env(:db_pre_request, nil),
        doc: """
        Name of a function (`schema.proc` or `proc`) run inside every request's
        transaction before the main query (PostgREST db-pre-request). It can
        inspect `request.*` settings and `SET LOCAL ROLE` or `RAISE` to abort.
        Applied only for auth-schema requests in the conformance build.
        """
      ],
      db_channel: [
        type: :string,
        default: env(:db_channel, "pgrst"),
        doc: """
        Postgres notification channel the schema-cache listener subscribes to
        (PostgREST db-channel). `NOTIFY <channel>, 'reload schema'` re-runs
        the DB introspection and atomically swaps the instance's schema
        cache; see `db_channel_enabled`.
        """
      ],
      db_channel_enabled: [
        type: :boolean,
        default: env(:db_channel_enabled, true),
        doc: """
        Whether the instance opens a dedicated LISTEN connection on
        `db_channel` and reloads its schema cache on NOTIFY (PostgREST
        db-channel-enabled). Enabled by default, matching PostgREST;
        disabling it saves one database connection per instance.
        `Bier.reload_schema_cache/1` works either way.
        """
      ],
      jwt_secret: [
        type: {:or, [:string, nil]},
        default: env(:jwt_secret, nil),
        doc: "Secret used to verify JWTs."
      ],
      jwt_aud: [
        type: {:or, [:string, nil]},
        default: env(:jwt_aud, nil),
        doc: """
        Expected JWT audience (PostgREST jwt-aud). When set, a presented token
        whose `aud` claim does not contain this value is rejected. When nil, the
        `aud` claim is ignored.
        """
      ],
      jwt_secret_is_base64: [
        type: :boolean,
        default: env(:jwt_secret_is_base64, false),
        doc: """
        When true, `jwt_secret` is base64-encoded and is decoded before use
        (PostgREST jwt-secret-is-base64). URL-safe characters (`-`, `_`, and
        `.` for padding) are accepted; a secret that fails to decode aborts
        startup.
        """
      ],
      jwt_role_claim_key: [
        type: :string,
        default: env(:jwt_role_claim_key, ".role"),
        doc: """
        JSPath to the database role inside the JWT claims (PostgREST
        jwt-role-claim-key), e.g. `.role` (default) or `."https://example.com/roles"[0]`.
        An expression that does not parse aborts startup.
        """
      ],
      jwt_cache_max_entries: [
        type: :integer,
        default: env(:jwt_cache_max_entries, 1000),
        doc: """
        Maximum number of JWT verification results cached per instance
        (PostgREST jwt-cache-max-entries). Signature verification and claims
        decoding are cached; temporal (`exp`/`nbf`) and audience validation
        still run on every request, so a cached token expires on time. A
        value of 0 or less disables the cache.
        """
      ],
      server_cors_allowed_origins: [
        type: {:or, [:string, nil]},
        default: env(:server_cors_allowed_origins, nil),
        doc: "Comma-separated list of CORS allowed origins."
      ],
      server_timing_enabled: [
        type: :boolean,
        default: env(:server_timing_enabled, false),
        doc: """
        When true, every response carries a `Server-Timing` header with the
        `jwt`, `parse`, `plan`, `transaction` and `response` phase durations
        (PostgREST server-timing-enabled). Defaults to false, in which case the
        header is omitted entirely.
        """
      ],
      server_trace_header: [
        type: {:or, [:string, nil]},
        default: env(:server_trace_header, nil),
        doc: """
        Name of a request header (e.g. `X-Request-Id`) to echo verbatim on the
        response (PostgREST server-trace-header). An empty string or nil makes
        the trace middleware a no-op.
        """
      ],
      log_level: [
        type: {:in, [:crit, :error, :warn, :info, :debug]},
        default: env(:log_level, :error),
        doc: """
        Access-log verbosity (PostgREST log-level). `crit` logs nothing;
        `error` logs status >= 500; `warn` logs status >= 400; `info`/`debug`
        log every response. Affects logging only, never the response itself.
        """
      ],
      openapi_mode: [
        type: {:in, ["follow-privileges", "ignore-privileges", "disabled"]},
        default: env(:openapi_mode, "follow-privileges"),
        doc: """
        How the root OpenAPI document is served (PostgREST openapi-mode).
        `disabled` makes the root endpoint return 404 PGRST126 instead of a spec.
        Under `follow-privileges`, the per-role privilege filtering of the
        document is cached and refreshes on schema-cache reload (matching
        PostgREST's reload-time freshness), so GRANT/REVOKE changes surface
        after a reload, not on the next request.
        """
      ],
      db_root_spec: [
        type: {:or, [:string, nil]},
        default: env(:db_root_spec, nil),
        doc: """
        Name of a DB function returning a custom root OpenAPI document
        (PostgREST db-root-spec). When set, the root endpoint serves its result
        instead of the generated spec.
        """
      ],
      openapi_server_proxy_uri: [
        type: {:or, [:string, nil]},
        default: env(:openapi_server_proxy_uri, nil),
        doc: """
        Public proxy URI the generated OpenAPI document advertises (PostgREST
        openapi-server-proxy-uri): its scheme/host/port/path become the
        document's `schemes`, `host` and `basePath`. Must be an absolute
        http(s) URI; a malformed value aborts startup.
        """
      ],
      app_settings: [
        type: {:map, :string, :string},
        default: env(:app_settings, %{}),
        doc: """
        Arbitrary `app.settings.<name>` GUCs set transaction-locally on each
        request that runs with the auth context (PostgREST app.settings.*;
        `PGRST_APP_SETTINGS_<NAME>` in the CLI). SQL reads them via
        `current_setting('app.settings.<name>')`.
        """
      ],
      openapi_security_active: [
        type: :boolean,
        default: env(:openapi_security_active, false),
        doc: """
        When `true`, the root OpenAPI document includes a top-level `security`
        requirement and a `JWT` apiKey `securityDefinitions` entry (PostgREST
        openapi-security-active). Defaults to `false`.
        """
      ],
      admin_server_port: [
        type: {:or, [:pos_integer, nil]},
        default: env(:admin_server_port, nil),
        doc: """
        TCP port for the per-instance admin server exposing the `/live` and
        `/ready` health endpoints (PostgREST admin-server-port). When `nil`
        (the default) no admin server starts. Must differ from `router[:port]`.
        """
      ],
      events_channels: [
        type: {:list, :string},
        default: env(:events_channels, []),
        doc: """
        Allowlist of Postgres notification channels exposed on the SSE events
        endpoint. The empty list (default) disables the feature entirely: no
        listener connection is opened and no path is reserved. Bier-specific
        (no PostgREST counterpart); see the Realtime events guide.
        """
      ],
      events_path: [
        type: :string,
        default: env(:events_path, "events"),
        doc: """
        Top-level path segment reserved for the SSE events endpoint while
        `events_channels` is non-empty. Change it if a relation of the same
        name must stay reachable. Must be a single segment (no `/`).
        """
      ],
      events_heartbeat_interval: [
        type: :pos_integer,
        default: env(:events_heartbeat_interval, 15_000),
        doc: """
        Milliseconds of silence on an SSE connection before a `: keepalive`
        comment frame is written. Keeps idle proxies from dropping the
        stream and bounds dead-client detection.
        """
      ]
    ]
  end

  defp env(key, default), do: Application.get_env(:bier, key, default)

  @doc """
  Starts a `Bier` supervision tree linked to the current process.

  ## Options

  #{NimbleOptions.docs(NimbleOptions.new!(name: [type: :atom, doc: "Used for the supervisor name registration."], router: [type: :non_empty_keyword_list, doc: "Bandit web endpoint options."]))}

  See `schema/0` for the full set of validated options (DB connection,
  `db_schemas`, etc.), whose defaults are sourced from application env.
  """
  @spec start_link(Keyword.t()) :: Supervisor.on_start()
  def start_link(opts) do
    conf = Bier.Config.new!(opts, schema())

    check_router_module_collision!(conf.name)

    Supervisor.start_link(__MODULE__, conf, name: Registry.via(conf.name, nil, conf))
  end

  # Two distinct instance names can concat to the same generated router module
  # (`Module.concat(A.B, Router)` and `Module.concat(:"A.B", Router)` both
  # yield `A.B.Router`), so a second instance would silently redefine the
  # first's router on every rebuild. Keyed on the LIVE instances registered in
  # `Bier.Registry` — not on the module already being defined — because after a
  # stop/restart of the same named instance the module legitimately still
  # exists and the boot must succeed.
  defp check_router_module_collision!(name) do
    router = Module.concat(name, Router)

    Registry.instance_names()
    |> Enum.find(&(&1 != name and Module.concat(&1, Router) == router))
    |> case do
      nil ->
        :ok

      other ->
        raise ArgumentError,
              "cannot start Bier instance #{inspect(name)}: its generated router module " <>
                "#{inspect(router)} collides with the one owned by the running instance " <>
                "#{inspect(other)} — pass a distinct :name"
    end
  end

  @spec child_spec(Keyword.t()) :: Supervisor.child_spec()
  def child_spec(opts) do
    opts
    |> super()
    |> Supervisor.child_spec(id: Keyword.get(opts, :name, __MODULE__))
  end

  @impl Supervisor
  def init(%Bier.Config{name: name} = conf) do
    children =
      [
        # Per-instance Postgrex pool, registered via the Bier registry so that the
        # introspection step and the request pipeline can resolve it from the
        # instance name. Started before HttpServerStarter, which needs it for the
        # boot-time DB introspection.
        Supervisor.child_spec({Postgrex, postgrex_opts(conf)}, id: {name, Postgrex}),
        # Samples the pool above on an interval and emits the
        # `[:bier, :pool, :status]` telemetry gauges (see Bier.Telemetry).
        {Bier.PoolMonitor, conf},
        # Owns the per-role privileges ETS cache used by the root OpenAPI
        # document (follow-privileges). Started before HttpServerStarter so
        # the table exists before the first request can arrive.
        {Bier.PrivilegesCache, conf}
      ] ++
        jwt_cache_children(conf) ++
        [
          # The DynamicSupervisor must start BEFORE HttpServerStarter: the latter's
          # `handle_continue(:start_webserver, …)` starts Bandit *as a child of this
          # DynamicSupervisor*, so it has to already be alive — otherwise that
          # `start_child` call races the DynamicSupervisor's own startup and crashes
          # (the supervisor then restarts HttpServerStarter, rebuilding the router).
          {DynamicSupervisor,
           strategy: :one_for_one, name: Registry.via(conf.name, DynamicSupervisor)},
          {Bier.HttpServerStarter, conf}
        ] ++ listener_children(conf) ++ events_children(conf) ++ admin_children(conf)

    Supervisor.init(children, strategy: :one_for_one)
  end

  # When `db_channel_enabled` (the default, matching PostgREST), run the
  # LISTEN/NOTIFY schema-cache listener. Started after HttpServerStarter so
  # the boot introspection has already populated the cache by the time the
  # listener first connects — its catch-up reload only applies to REconnects.
  # The listener owns its DB connection and retries with internal backoff, so
  # a database outage never builds restart pressure on this supervisor.
  defp listener_children(%Bier.Config{db_channel_enabled: false}), do: []

  defp listener_children(%Bier.Config{} = conf), do: [{Bier.SchemaCacheListener, conf}]

  # When any events_channels are configured, run the SSE events listener —
  # a second dedicated LISTEN connection, deliberately separate from the
  # schema-cache listener so user-facing streaming never couples to reload
  # semantics. It owns its DB connection and retries with internal backoff,
  # so a database outage never builds restart pressure on this supervisor.
  # Like `listener_children/1`, this starts AFTER HttpServerStarter, so the
  # API can briefly accept SSE subscriptions before the first LISTEN is up —
  # acceptable under the documented fire-and-forget contract (events fired in
  # that gap are silently lost; tests wait for the listener to connect before
  # asserting delivery).
  defp events_children(%Bier.Config{events_channels: []}), do: []

  defp events_children(%Bier.Config{} = conf), do: [{Bier.Events.Listener, conf}]

  # The JWT verification cache only runs when it can do work: a secret is
  # configured and jwt-cache-max-entries is positive (PostgREST's JwtNoCache
  # mode otherwise). Auth falls back to direct verification when absent.
  defp jwt_cache_children(conf) do
    if Bier.JwtCache.enabled?(conf), do: [{Bier.JwtCache, conf}], else: []
  end

  # When `admin_server_port` is set, run a second Bandit listener serving the
  # admin health endpoints (separate from the catch-all API router). Started
  # statically here — it needs no introspection result; `/ready` reports 503
  # until the schema cache is populated, which is the correct readiness signal.
  # (Boot ordering after HttpServerStarter means the cache is populated before
  # this listener binds on the initial boot; across an HttpServerStarter restart
  # the admin listener keeps serving the last persistent_term cache.)
  defp admin_children(%Bier.Config{admin_server_port: nil}), do: []

  defp admin_children(%Bier.Config{name: name, admin_server_port: port} = conf) do
    [
      Supervisor.child_spec(
        {
          Bandit,
          # The admin listener is TCP-only (as in PostgREST) but honors the
          # shared server-host bind address.
          scheme: conf.router[:scheme],
          plug: {Bier.Plugs.AdminRouter, name: name},
          ip: Bier.Config.host_address(conf.server_host),
          port: port,
          http_options: [compress: false]
        },
        id: {name, :admin_server}
      )
    ]
  end

  @doc false
  def postgrex_opts(%Bier.Config{} = conf) do
    [
      name: Registry.via(conf.name, Postgrex),
      hostname: conf.hostname,
      port: conf.port,
      database: conf.database,
      username: conf.username,
      password: conf.password,
      ssl: conf.ssl,
      pool_size: conf.pool_size,
      # db-pool-max-idletime (seconds) -> DBConnection's idle-connection
      # interval (milliseconds); nil defers to the driver default.
      idle_interval: conf.db_pool_max_idletime && conf.db_pool_max_idletime * 1000,
      # PostgREST renders timestamptz in UTC by default; pin the session timezone
      # so timestamptz output (and DOMAIN representations built on it) is stable
      # and matches the reference DB regardless of the server's local TZ. A
      # per-request `Prefer: timezone=` still overrides this via SET LOCAL.
      parameters: [timezone: "UTC"]
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  @doc """
  Returns the configured JSON encoding library for Bier.

  To customize the JSON library, including the following
  in your `config/config.exs`:

      config :bier, :json_library, AlternativeJsonLibrary

  """
  def json_library do
    Application.get_env(:bier, :json_library, JSON)
  end

  @doc """
  Re-runs the database introspection for the running instance `name` and
  atomically swaps its schema cache — the programmatic equivalent of
  PostgREST's `NOTIFY pgrst, 'reload schema'` (or SIGUSR1).

  Works whether or not the instance's LISTEN/NOTIFY listener is enabled
  (`db_channel_enabled`). Returns `{:error, :unknown_instance}` when no
  instance is registered under `name`; an introspection failure leaves the
  previous cache serving and is returned as `{:error, reason}`.
  """
  @spec reload_schema_cache(name()) :: :ok | {:error, term()}
  defdelegate reload_schema_cache(name), to: Bier.SchemaCache, as: :reload
end
