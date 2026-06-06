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
      pool_size: [
        type: :pos_integer,
        default: env(:pool_size, 10),
        doc: "Size of the per-instance Postgrex connection pool."
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

    Supervisor.start_link(__MODULE__, conf, name: Registry.via(conf.name, nil, conf))
  end

  @spec child_spec(Keyword.t()) :: Supervisor.child_spec()
  def child_spec(opts) do
    opts
    |> super()
    |> Supervisor.child_spec(id: Keyword.get(opts, :name, __MODULE__))
  end

  @impl Supervisor
  def init(%Bier.Config{name: name} = conf) do
    children = [
      # Per-instance Postgrex pool, registered via the Bier registry so that the
      # introspection step and the request pipeline can resolve it from the
      # instance name. Started before HttpServerStarter, which needs it for the
      # boot-time DB introspection.
      Supervisor.child_spec({Postgrex, postgrex_opts(conf)}, id: {name, Postgrex}),
      {Bier.HttpServerStarter, conf},
      {DynamicSupervisor,
       strategy: :one_for_one, name: Registry.via(conf.name, DynamicSupervisor)}
    ]

    Supervisor.init(children, strategy: :one_for_one)
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
      pool_size: conf.pool_size,
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
end
