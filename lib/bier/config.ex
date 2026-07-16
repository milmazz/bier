defmodule Bier.Config do
  @moduledoc """
  Defines and validates the internal configuration needed by `Bier` processes.

  The options given to `Bier.start_link/1` are validated via `new!/2` using the
  internal schema, if the given options are valid, the configuration will be
  wrapped in a #{__MODULE__} struct, which subsequently will be stored in the
  `Bier.Registry`. Internal modules will also consume this configuration to work
  properly.
  """

  alias Bier.JWT.RoleClaim

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
          ssl: boolean(),
          pool_size: pos_integer(),
          db_pool_max_idletime: pos_integer() | nil,
          server_host: String.t(),
          server_unix_socket: String.t() | nil,
          server_unix_socket_mode: String.t(),
          openapi_server_proxy_uri: String.t() | nil,
          app_settings: %{optional(String.t()) => String.t()},
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
          db_channel: String.t(),
          db_channel_enabled: boolean(),
          jwt_secret: String.t() | nil,
          jwt_secret_is_base64: boolean(),
          jwt_aud: String.t() | nil,
          jwt_role_claim_path: RoleClaim.path(),
          jwt_cache_max_entries: integer(),
          server_cors_allowed_origins: String.t() | nil,
          server_timing_enabled: boolean(),
          server_trace_header: String.t() | nil,
          log_level: :crit | :error | :warn | :info | :debug,
          openapi_mode: String.t(),
          openapi_security_active: boolean(),
          db_root_spec: String.t() | nil,
          admin_server_port: pos_integer() | nil,
          events_channels: [String.t()],
          events_path: String.t(),
          events_heartbeat_interval: pos_integer()
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
    :server_unix_socket,
    :openapi_server_proxy_uri,
    :db_pool_max_idletime,
    name: Bier,
    server_host: "!4",
    server_unix_socket_mode: "660",
    app_settings: %{},
    ssl: false,
    openapi_mode: "follow-privileges",
    openapi_security_active: false,
    pool_size: 10,
    db_schemas: ["public"],
    db_extra_search_path: ["public"],
    db_max_rows_by_schema: %{},
    db_schema_aliases: %{},
    db_plan_enabled: false,
    db_tx_end: :commit,
    db_safe_update_tables: [],
    db_channel: "pgrst",
    db_channel_enabled: true,
    server_timing_enabled: false,
    log_level: :error,
    jwt_secret_is_base64: false,
    jwt_role_claim_path: [{:key, "role"}],
    jwt_cache_max_entries: 1000,
    events_channels: [],
    events_path: "events",
    events_heartbeat_interval: 15_000
  ]

  @doc """
  Validates the given options based on the internal schema definition

  In case the given options are valid, it returns a `Bier.Config` struct,
  otherwise it will raise an exception.
  """
  @spec new!(Keyword.t(), Keyword.t()) :: t() | no_return()
  def new!(opts, schema) do
    case new(opts, schema) do
      {:ok, conf} -> conf
      {:error, message} -> raise ArgumentError, message
    end
  end

  @doc """
  Non-raising variant of `new!/2`: validates the given options against the
  schema plus the semantic validators and returns `{:ok, config}` or
  `{:error, message}`. The standalone/CLI boot path uses this to turn a bad
  config into a clean fatal message instead of a raised exception.
  """
  @spec new(Keyword.t(), Keyword.t()) :: {:ok, t()} | {:error, String.t()}
  def new(opts, schema) do
    with {:ok, conf} <- validate_schema(opts, schema),
         :ok <-
           validate_admin_server_port(conf[:admin_server_port], get_in(conf, [:router, :port])),
         :ok <- validate_jwt_secret(conf[:jwt_secret]),
         :ok <- validate_jwt_aud(conf[:jwt_aud]),
         :ok <- validate_db_channel(conf[:db_channel]),
         :ok <- validate_socket_mode(Keyword.get(conf, :server_unix_socket_mode, "660")),
         :ok <- validate_proxy_uri(conf[:openapi_server_proxy_uri]),
         :ok <- validate_events_channels(Keyword.get(conf, :events_channels, [])),
         :ok <- validate_events_path(Keyword.get(conf, :events_path, "events")),
         {:ok, conf} <- decode_jwt_secret(conf),
         {:ok, conf} <- parse_jwt_role_claim_key(conf) do
      {:ok, struct!(__MODULE__, conf)}
    end
  end

  # jwt-secret-is-base64: decode the configured secret before use, exactly like
  # PostgREST's decodeSecret (Config.hs#L479-L488): URL-safe chars normalized
  # (`-`->`+`, `_`->`/`, `.`->`=`), whitespace stripped, then a strict base64
  # decode; failure is fatal (conformance case 1718). PostgREST checks the
  # 32-byte minimum on the raw (pre-decode) text, hence decoding after
  # validate_jwt_secret above.
  defp decode_jwt_secret(conf) do
    case {Keyword.get(conf, :jwt_secret_is_base64, false), conf[:jwt_secret]} do
      {true, secret} when is_binary(secret) ->
        case decode_base64_secret(secret) do
          {:ok, decoded} -> {:ok, Keyword.put(conf, :jwt_secret, decoded)}
          {:error, _} = err -> err
        end

      _other ->
        {:ok, conf}
    end
  end

  @doc """
  Decode a base64 `jwt-secret` (jwt-secret-is-base64), accepting URL-safe
  characters the way PostgREST does. Shared with the CLI so `--dump-config`
  rejects an undecodable secret identically (case 1718).
  """
  @spec decode_base64_secret(String.t()) :: {:ok, binary()} | {:error, String.t()}
  def decode_base64_secret(secret) do
    normalized =
      secret
      |> String.replace(".", "=")
      |> String.replace("-", "+")
      |> String.replace("_", "/")
      |> String.trim()

    case Base.decode64(normalized) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, "the jwt-secret is not valid base64"}
    end
  end

  # jwt-role-claim-key: parse the JSPath once at boot and carry only the parsed
  # path in the struct (per-request role extraction never re-parses; the raw
  # text can be reconstructed with RoleClaim.dump/1). An invalid expression is
  # fatal with PostgREST's message (conformance case 1711).
  defp parse_jwt_role_claim_key(conf) do
    case RoleClaim.parse(Keyword.get(conf, :jwt_role_claim_key, ".role")) do
      {:ok, path} ->
        {:ok,
         conf |> Keyword.delete(:jwt_role_claim_key) |> Keyword.put(:jwt_role_claim_path, path)}

      {:error, _} = err ->
        err
    end
  end

  defp validate_schema(opts, schema) do
    case NimbleOptions.validate(opts, schema) do
      {:ok, conf} -> {:ok, conf}
      {:error, %NimbleOptions.ValidationError{} = error} -> {:error, Exception.message(error)}
    end
  end

  @doc """
  A symmetric (text) JWT secret must be at least 32 bytes long — PostgREST
  counts the secret's octets (`BS.length` in Config.hs), not characters, so
  Bier does too. `nil` (no secret configured) is allowed. Mirrors PostgREST
  conformance case 1708.
  """
  @spec validate_jwt_secret(String.t() | nil) :: :ok | {:error, String.t()}
  def validate_jwt_secret(nil), do: :ok

  def validate_jwt_secret(secret) when is_binary(secret) do
    if byte_size(secret) >= 32 do
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

  @doc """
  `db-channel` must be a non-empty channel name of at most 63 bytes (the
  Postgres identifier limit) and must not contain a null byte.
  `Postgrex.Notifications.listen/3` enforces both the length bound and the
  null-byte restriction at runtime by raising — validating at boot turns a
  would-be listener crash-loop into a fast `ArgumentError`. Library-enforced
  (PostgREST does not validate this key), like the admin-port collision rule.
  """
  @spec validate_db_channel(String.t() | nil) :: :ok | {:error, String.t()}
  def validate_db_channel(nil), do: :ok

  def validate_db_channel(channel) when is_binary(channel) do
    cond do
      channel == "" -> {:error, "db-channel cannot be empty"}
      byte_size(channel) > 63 -> {:error, "db-channel cannot exceed 63 bytes"}
      String.contains?(channel, <<0>>) -> {:error, "db-channel cannot contain null bytes"}
      true -> :ok
    end
  end

  @doc """
  Parse a `server-unix-socket-mode` value the way PostgREST does (Haskell's
  `readOct`): the longest leading run of octal digits is the value — so `"599"`
  reads as `5` (range error) while `"800"` has no octal prefix at all — and the
  result must lie between `0o600` and `0o777`. Returns the integer file mode
  for `File.chmod/2`. Mirrors conformance cases 1714/1715.
  """
  @spec parse_socket_mode(String.t()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def parse_socket_mode(mode) when is_binary(mode) do
    case Integer.parse(mode, 8) do
      {value, _rest} when value >= 0o600 and value <= 0o777 ->
        {:ok, value}

      {_value, _rest} ->
        {:error, "Invalid server-unix-socket-mode: needs to be between 600 and 777"}

      :error ->
        {:error, "Invalid server-unix-socket-mode: not an octal"}
    end
  end

  @doc "Boolean-style wrapper over `parse_socket_mode/1` for the validation chain."
  @spec validate_socket_mode(String.t()) :: :ok | {:error, String.t()}
  def validate_socket_mode(mode) do
    with {:ok, _value} <- parse_socket_mode(mode), do: :ok
  end

  @doc """
  `openapi-server-proxy-uri` must be an absolute http(s) URI with a host —
  PostgREST's `isMalformedProxyUri` check. `nil` (not configured) is allowed.
  Mirrors conformance case 1716.
  """
  @spec validate_proxy_uri(String.t() | nil) :: :ok | {:error, String.t()}
  def validate_proxy_uri(nil), do: :ok

  def validate_proxy_uri(uri) when is_binary(uri) do
    case URI.new(uri) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        :ok

      _other ->
        {:error, "Malformed proxy uri, a correct example: https://example.com:8443/basePath"}
    end
  end

  @doc """
  Translate a `server-host` value into a `:gen_tcp` bind address. PostgREST's
  key is a Warp `HostPreference`: `"*"`/`"*4"`/`"!4"` bind any IPv4 interface
  and `"*6"`/`"!6"` any IPv6 one (the IPv4-vs-IPv6 *preference* the `*` forms
  express has no counterpart in a single bind call). Anything else is an IP
  literal or a host name resolved at boot; an unresolvable name raises, which
  surfaces as a boot failure.
  """
  @spec host_address(String.t()) :: :inet.socket_address()
  def host_address(host) when host in ["*", "*4", "!4"], do: {0, 0, 0, 0}
  def host_address(host) when host in ["*6", "!6"], do: {0, 0, 0, 0, 0, 0, 0, 0}

  def host_address(host) when is_binary(host) do
    chars = String.to_charlist(host)

    with {:error, _} <- :inet.parse_address(chars),
         {:error, _} <- :inet.getaddr(chars, :inet),
         {:error, _} <- :inet.getaddr(chars, :inet6) do
      raise ArgumentError, "server-host #{inspect(host)} is not a bindable address"
    else
      {:ok, address} -> address
    end
  end

  @doc """
  `admin-server-port` must differ from the main server port. Mirrors PostgREST
  (test_cli.py:test_server_port_and_admin_port_same_value; conformance case
  1717). NimbleOptions validates fields independently, so this cross-field
  check lives here, shared by `new!/2` and the CLI. Either port may be `nil`
  when not configured.
  """
  @spec validate_admin_server_port(pos_integer() | nil, pos_integer() | nil) ::
          :ok | {:error, String.t()}
  def validate_admin_server_port(admin_port, server_port) do
    if not is_nil(admin_port) and admin_port == server_port do
      {:error, "admin-server-port cannot be the same as server-port"}
    else
      :ok
    end
  end

  @doc """
  Each `events-channels` entry must be a usable Postgres notification channel
  name: non-empty, at most 63 bytes (the identifier limit), no null bytes, and
  no double quotes (`Postgrex.Notifications.listen/3` wraps the name in double
  quotes without escaping). Validated at boot so a bad entry is a fast
  `ArgumentError` instead of a listener crash-loop. Bier-specific key.
  """
  @spec validate_events_channels([String.t()]) :: :ok | {:error, String.t()}
  def validate_events_channels(channels) when is_list(channels) do
    Enum.find_value(channels, :ok, fn channel ->
      case validate_channel_name(channel) do
        :ok -> nil
        {:error, _} = err -> err
      end
    end)
  end

  defp validate_channel_name(channel) do
    cond do
      channel == "" ->
        {:error, "events-channels entries cannot be empty"}

      byte_size(channel) > 63 ->
        {:error, "events-channels entries cannot exceed 63 bytes"}

      String.contains?(channel, <<0>>) ->
        {:error, "events-channels entries cannot contain null bytes"}

      String.contains?(channel, "\"") ->
        {:error, "events-channels entries cannot contain double quotes"}

      true ->
        :ok
    end
  end

  @doc """
  `events-path` is the reserved top-level path segment for the SSE endpoint,
  so it must be non-empty and must not contain `/`.
  """
  @spec validate_events_path(String.t()) :: :ok | {:error, String.t()}
  def validate_events_path(path) when is_binary(path) do
    cond do
      path == "" ->
        {:error, "events-path cannot be empty"}

      String.contains?(path, "/") ->
        {:error, "events-path must be a single path segment (no '/')"}

      true ->
        :ok
    end
  end
end
