defmodule Bier.Config do
  @moduledoc """
  Defines and validates the internal configuration needed by `Bier` processes.

  The options given to `Bier.start_link/1` are validated via `new!/2` using the
  internal schema, if the given options are valid, the configuration will be
  wrapped in a #{__MODULE__} struct, which subsequently will be stored in the
  `Bier.Registry`. Internal modules will also consume this configuration to work
  properly.
  """

  @typedoc """
  Options given to `Bandit`
  """
  @type router_opts :: [
          port: pos_integer(),
          scheme: :http | :https
        ]

  @type t :: %__MODULE__{
          name: module(),
          router: router_opts(),
          hostname: String.t(),
          port: pos_integer(),
          database: String.t(),
          username: String.t() | nil,
          password: String.t() | nil,
          pool_size: pos_integer(),
          db_schemas: [String.t(), ...],
          db_profile_default: String.t() | nil,
          db_profile_schemas: [String.t()] | nil,
          db_schema_aliases: %{optional(String.t()) => String.t()},
          db_anon_role: String.t() | nil,
          db_extra_search_path: [String.t()],
          db_max_rows: pos_integer() | nil,
          db_max_rows_by_schema: %{optional(String.t()) => pos_integer()},
          db_plan_enabled: boolean(),
          db_tx_end: :commit | :rollback,
          db_safe_update_tables: [String.t()],
          db_pre_request: String.t() | nil,
          jwt_secret: String.t() | nil,
          jwt_aud: String.t() | nil,
          server_cors_allowed_origins: String.t() | nil,
          server_timing_enabled: boolean(),
          server_trace_header: String.t() | nil,
          log_level: :crit | :error | :warn | :info | :debug
        }

  defstruct [
    :router,
    :hostname,
    :port,
    :database,
    :username,
    :password,
    :db_anon_role,
    :db_max_rows,
    :db_pre_request,
    :jwt_secret,
    :jwt_aud,
    :server_cors_allowed_origins,
    :db_profile_default,
    :db_profile_schemas,
    :server_trace_header,
    name: Bier,
    pool_size: 10,
    db_schemas: ["public"],
    db_extra_search_path: ["public"],
    db_max_rows_by_schema: %{},
    db_schema_aliases: %{},
    db_plan_enabled: false,
    db_tx_end: :commit,
    db_safe_update_tables: [],
    server_timing_enabled: false,
    log_level: :error
  ]

  @doc """
  Validates the given options based on the internal schema definition

  In case the given options are valid, it returns a `Bier.Config` struct,
  otherwise it will raise an exception.
  """
  @spec new!(Keyword.t(), Keyword.t()) :: t() | no_return()
  def new!(opts, schema) do
    conf = NimbleOptions.validate!(opts, schema)

    struct!(__MODULE__, conf)
  end
end
