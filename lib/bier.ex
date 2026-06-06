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
      jwt_secret: [
        type: {:or, [:string, nil]},
        default: env(:jwt_secret, nil),
        doc: "Secret used to verify JWTs."
      ],
      server_cors_allowed_origins: [
        type: {:or, [:string, nil]},
        default: env(:server_cors_allowed_origins, nil),
        doc: "Comma-separated list of CORS allowed origins."
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
      pool_size: conf.pool_size
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
