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
          log_level: :crit | :error | :warn | :info | :debug,
          openapi_mode: String.t(),
          db_root_spec: String.t() | nil,
          admin_server_port: pos_integer() | nil
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
    :db_root_spec,
    :admin_server_port,
    name: Bier,
    openapi_mode: "follow-privileges",
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

    validate_admin_server_port!(conf)
    raise_if_error!(validate_jwt_secret(conf[:jwt_secret]))
    raise_if_error!(validate_jwt_aud(conf[:jwt_aud]))

    struct!(__MODULE__, conf)
  end

  @doc """
  A symmetric (text) JWT secret must be at least 32 characters long. `nil`
  (no secret configured) is allowed. Mirrors PostgREST conformance case 1708.
  """
  @spec validate_jwt_secret(String.t() | nil) :: :ok | {:error, String.t()}
  def validate_jwt_secret(nil), do: :ok

  def validate_jwt_secret(secret) when is_binary(secret) do
    if String.length(secret) >= 32 do
      :ok
    else
      {:error, "The JWT secret must be at least 32 characters long."}
    end
  end

  @doc """
  `jwt-aud` may be any plain string, but a value containing ':' must parse as a
  valid absolute URI. Mirrors PostgREST conformance case 1709.
  """
  @spec validate_jwt_aud(String.t() | nil) :: :ok | {:error, String.t()}
  def validate_jwt_aud(nil), do: :ok

  def validate_jwt_aud(aud) when is_binary(aud) do
    if not String.contains?(aud, ":") or valid_uri?(aud) do
      :ok
    else
      {:error, "jwt-aud should be a string or a valid URI"}
    end
  end

  # Mirrors PostgREST's `isURI` (Network.URI): any absolute RFC 3986 URI is
  # valid, including opaque URIs / URNs (scheme, no authority) like
  # "urn:example:audience". A host is NOT required.
  defp valid_uri?(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: scheme}} when is_binary(scheme) and scheme != "" -> true
      _ -> false
    end
  end

  # PostgREST rejects an admin-server-port equal to server-port at startup
  # (test_cli.py:test_server_port_and_admin_port_same_value; conformance case
  # 1717). NimbleOptions validates fields independently, so this cross-field
  # check lives here.
  defp validate_admin_server_port!(conf) do
    admin_port = conf[:admin_server_port]
    server_port = get_in(conf, [:router, :port])

    if not is_nil(admin_port) and admin_port == server_port do
      raise ArgumentError, "admin-server-port cannot be the same as server-port"
    end
  end

  defp raise_if_error!(:ok), do: :ok
  defp raise_if_error!({:error, message}), do: raise(ArgumentError, message)
end
