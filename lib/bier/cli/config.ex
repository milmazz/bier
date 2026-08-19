defmodule Bier.CLI.Config do
  @moduledoc """
  The PostgREST config dialect ↔ Bier boundary.

  `spec/0` is the single source of truth: one entry per PostgREST config key
  that Bier implements, carrying its `PGRST_*` env var, deprecated aliases,
  value type, and PostgREST default (used for `--dump-config`). Keys Bier does
  not implement are intentionally absent — their conformance cases stay
  deferred.
  """

  alias Bier.JWT.RoleClaim

  # kind:
  #   :string | :opt_string | :int | :opt_int | :bool
  #   :csv | :csv_emptyable
  #   {:enum_atom, name} | {:enum_str, name}
  # default: the PostgREST default, rendered by dump/1 when unset.
  @entries [
    %{key: "db-uri", env: "PGRST_DB_URI", kind: :string, default: "postgresql://", aliases: []},
    %{
      key: "client-error-verbosity",
      env: "PGRST_CLIENT_ERROR_VERBOSITY",
      kind: {:enum_str, :client_error_verbosity},
      default: "verbose",
      aliases: []
    },
    %{
      key: "db-schemas",
      env: "PGRST_DB_SCHEMAS",
      kind: :csv,
      default: ["public"],
      aliases: ["db-schema"]
    },
    %{
      key: "db-anon-role",
      env: "PGRST_DB_ANON_ROLE",
      kind: :opt_string,
      default: :unset,
      aliases: []
    },
    %{
      key: "db-channel",
      env: "PGRST_DB_CHANNEL",
      kind: :string,
      default: "pgrst",
      aliases: []
    },
    %{
      key: "db-channel-enabled",
      env: "PGRST_DB_CHANNEL_ENABLED",
      kind: :bool,
      default: true,
      aliases: []
    },
    %{
      key: "db-config",
      env: "PGRST_DB_CONFIG",
      kind: :bool,
      default: true,
      aliases: []
    },
    %{
      key: "db-extra-search-path",
      env: "PGRST_DB_EXTRA_SEARCH_PATH",
      kind: :csv_emptyable,
      default: ["public"],
      aliases: []
    },
    %{
      key: "db-max-rows",
      env: "PGRST_DB_MAX_ROWS",
      kind: :opt_int,
      default: :unset,
      aliases: ["max-rows"]
    },
    %{key: "db-pool", env: "PGRST_DB_POOL", kind: :int, default: 10, aliases: []},
    %{
      key: "db-pool-max-idletime",
      env: "PGRST_DB_POOL_MAX_IDLETIME",
      kind: :int,
      default: 30,
      aliases: ["db-pool-timeout"]
    },
    %{
      key: "db-prepared-statements",
      env: "PGRST_DB_PREPARED_STATEMENTS",
      kind: :bool,
      default: true,
      aliases: []
    },
    %{
      key: "db-tx-end",
      env: "PGRST_DB_TX_END",
      kind: {:enum_atom, :db_tx_end},
      default: :commit,
      aliases: []
    },
    %{
      key: "db-pre-request",
      env: "PGRST_DB_PRE_REQUEST",
      kind: :opt_string,
      default: :unset,
      aliases: ["pre-request"]
    },
    %{
      key: "db-root-spec",
      env: "PGRST_DB_ROOT_SPEC",
      kind: :opt_string,
      default: :unset,
      aliases: ["root-spec"]
    },
    %{key: "server-port", env: "PGRST_SERVER_PORT", kind: :int, default: 3000, aliases: []},
    %{key: "server-host", env: "PGRST_SERVER_HOST", kind: :string, default: "!4", aliases: []},
    %{
      key: "server-reuseport",
      env: "PGRST_SERVER_REUSEPORT",
      kind: :bool,
      default: false,
      aliases: []
    },
    %{
      key: "url-use-legacy-target-names",
      env: "PGRST_URL_USE_LEGACY_TARGET_NAMES",
      kind: :bool,
      default: true,
      aliases: []
    },
    %{
      key: "server-unix-socket",
      env: "PGRST_SERVER_UNIX_SOCKET",
      kind: :opt_string,
      default: :unset,
      aliases: []
    },
    %{
      key: "server-unix-socket-mode",
      env: "PGRST_SERVER_UNIX_SOCKET_MODE",
      kind: :string,
      default: "660",
      aliases: []
    },
    %{
      key: "openapi-server-proxy-uri",
      env: "PGRST_OPENAPI_SERVER_PROXY_URI",
      kind: :opt_string,
      default: :unset,
      aliases: []
    },
    %{
      key: "admin-server-port",
      env: "PGRST_ADMIN_SERVER_PORT",
      kind: :opt_int,
      default: :unset,
      aliases: []
    },
    %{
      key: "admin-server-unix-socket",
      env: "PGRST_ADMIN_SERVER_UNIX_SOCKET",
      kind: :opt_string,
      default: :unset,
      aliases: []
    },
    %{
      key: "admin-server-unix-socket-mode",
      env: "PGRST_ADMIN_SERVER_UNIX_SOCKET_MODE",
      kind: :string,
      default: "660",
      aliases: []
    },
    %{
      key: "jwt-secret",
      env: "PGRST_JWT_SECRET",
      kind: :opt_string,
      default: :unset,
      aliases: []
    },
    %{key: "jwt-aud", env: "PGRST_JWT_AUD", kind: :opt_string, default: :unset, aliases: []},
    %{
      key: "jwt-secret-is-base64",
      env: "PGRST_JWT_SECRET_IS_BASE64",
      kind: :bool,
      default: false,
      aliases: ["secret-is-base64"]
    },
    %{
      key: "jwt-role-claim-key",
      env: "PGRST_JWT_ROLE_CLAIM_KEY",
      kind: :string,
      default: "$.role",
      aliases: ["role-claim-key"]
    },
    %{
      key: "jwt-cache-max-entries",
      env: "PGRST_JWT_CACHE_MAX_ENTRIES",
      kind: :int,
      default: 1000,
      aliases: []
    },
    %{
      key: "openapi-mode",
      env: "PGRST_OPENAPI_MODE",
      kind: {:enum_str, :openapi_mode},
      default: "follow-privileges",
      aliases: []
    },
    %{
      key: "openapi-security-active",
      env: "PGRST_OPENAPI_SECURITY_ACTIVE",
      kind: :bool,
      default: false,
      aliases: []
    },
    %{
      key: "log-level",
      env: "PGRST_LOG_LEVEL",
      kind: {:enum_atom, :log_level},
      default: :error,
      aliases: []
    },
    %{
      key: "log-query",
      env: "PGRST_LOG_QUERY",
      kind: :bool,
      default: false,
      aliases: []
    },
    %{
      key: "server-cors-allowed-origins",
      env: "PGRST_SERVER_CORS_ALLOWED_ORIGINS",
      kind: :opt_string,
      default: :unset,
      aliases: []
    },
    %{
      key: "db-plan-enabled",
      env: "PGRST_DB_PLAN_ENABLED",
      kind: :bool,
      default: false,
      aliases: []
    },
    %{
      key: "server-trace-header",
      env: "PGRST_SERVER_TRACE_HEADER",
      kind: :opt_string,
      default: :unset,
      aliases: []
    },
    %{
      key: "server-timing-enabled",
      env: "PGRST_SERVER_TIMING_ENABLED",
      kind: :bool,
      default: false,
      aliases: []
    }
  ]

  @enum_atoms %{
    log_level: %{
      values: %{
        "crit" => :crit,
        "error" => :error,
        "warn" => :warn,
        "info" => :info,
        "debug" => :debug
      },
      message: "Invalid logging level. Check your configuration."
    },
    db_tx_end: %{
      values: %{
        "commit" => :commit,
        "commit-allow-override" => :"commit-allow-override",
        "rollback" => :rollback,
        "rollback-allow-override" => :"rollback-allow-override"
      },
      message: "Invalid transaction termination. Check your configuration."
    }
  }

  @enum_strs %{
    openapi_mode: %{
      values: ["follow-privileges", "ignore-privileges", "disabled"],
      message: "Invalid openapi-mode. Check your configuration."
    },
    client_error_verbosity: %{
      values: ["minimal", "verbose"],
      message: "Invalid client-error-verbosity. Check your configuration."
    }
  }

  @doc "The config key spec table (one entry per implemented PostgREST key)."
  @spec spec() :: [map()]
  def spec, do: @entries

  # Keys settable from the in-database config source (`ALTER ROLE ... SET
  # pgrst.*`): upstream's dbSettingsNames whitelist (Config/Database.hs,
  # v16.0) intersected with the keys Bier implements. Upstream-only names not
  # mirrored here: db_aggregates_enabled, db_pre_config, db_hoisted_tx_settings,
  # jwt_cache_max_lifetime (Bier's jwt-cache-max-entries is a different knob).
  # Everything else — notably server-* bind settings and db-uri — is
  # non-reloadable and ignored when set via the database (case 1725).
  @db_settable_keys ~w(
    client-error-verbosity
    db-anon-role db-extra-search-path db-max-rows db-plan-enabled
    db-pre-request db-prepared-statements db-root-spec db-schemas db-tx-end
    jwt-aud jwt-role-claim-key jwt-secret jwt-secret-is-base64
    openapi-mode openapi-security-active openapi-server-proxy-uri
    server-cors-allowed-origins server-trace-header server-timing-enabled
    url-use-legacy-target-names
  )

  @doc """
  The `pgrst.*` setting names the in-database config source accepts — the
  `k = ANY(...)` filter of the role-settings query (PostgREST
  Config/Database.hs `dbSettingsNames`).
  """
  @spec db_settings_names() :: [String.t()]
  def db_settings_names do
    for key <- @db_settable_keys, do: "pgrst." <> String.replace(key, "-", "_")
  end

  @type kind ::
          :string
          | :opt_string
          | :int
          | :opt_int
          | :bool
          | :csv
          | :csv_emptyable
          | {:enum_atom, atom()}
          | {:enum_str, atom()}

  @doc """
  Coerce a raw value (string from env/file, or already-typed from the file
  parser) to the typed value for `kind`. `:unset` marks an absent optional
  value (falls back to default). Enum mismatches return PostgREST's message.
  """
  @spec coerce(kind(), term()) :: {:ok, term()} | {:error, String.t()}
  def coerce(:string, v), do: {:ok, to_string(v)}

  def coerce(:opt_string, v) do
    case to_string(v) do
      "" -> {:ok, :unset}
      s -> {:ok, s}
    end
  end

  def coerce(:int, v) do
    case parse_int(v) do
      {:ok, int} -> {:ok, int}
      :error -> {:ok, :unset}
    end
  end

  def coerce(:opt_int, v) do
    case parse_int(v) do
      {:ok, int} -> {:ok, int}
      :error -> {:ok, :unset}
    end
  end

  # Mirrors PostgREST's coerceBool (Config.hs): the value's *alpha* characters
  # are title-cased and read as a Haskell Bool, so "true", "TRUE" and even the
  # doubly-quoted "\"true\"" all parse (cases 1741). When that yields nothing —
  # e.g. the value is all digits — the whole value is read as an Integer and
  # `> 0` decides, making "1"/"2" true and "0" false (case 1740). Anything else
  # is Nothing, which `resolve/5` turns into the key's default.
  def coerce(:bool, v) when is_boolean(v), do: {:ok, v}

  def coerce(:bool, v) when is_integer(v), do: {:ok, v > 0}

  def coerce(:bool, v) do
    s = to_string(v)

    case s |> String.replace(~r/[^[:alpha:]]/u, "") |> String.downcase() do
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _other -> {:ok, bool_from_integer(s)}
    end
  end

  def coerce(:csv, v), do: {:ok, split_csv(to_string(v))}

  def coerce(:csv_emptyable, v) do
    case to_string(v) do
      "" -> {:ok, []}
      s -> {:ok, split_csv(s)}
    end
  end

  def coerce({:enum_atom, name}, v) do
    %{values: values, message: message} = Map.fetch!(@enum_atoms, name)

    case Map.fetch(values, to_string(v)) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, message}
    end
  end

  def coerce({:enum_str, name}, v) do
    %{values: values, message: message} = Map.fetch!(@enum_strs, name)
    s = to_string(v)
    if s in values, do: {:ok, s}, else: {:error, message}
  end

  defp bool_from_integer(s) do
    case Integer.parse(s) do
      {int, ""} -> int > 0
      _other -> :unset
    end
  end

  defp parse_int(v) when is_integer(v), do: {:ok, v}

  defp parse_int(v) do
    case Integer.parse(to_string(v)) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end

  defp split_csv(s) do
    s |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  @doc """
  Resolve every spec key from flags > db > env > file > default, applying
  aliases and coercion, then run the shared semantic validators. Returns the
  resolved `%{kebab_key => typed_value}` map, or `{:error, message}` on a
  fatal problem.

  `env` is a `%{"PGRST_*" => string}` map (the caller supplies it — the core
  never reads `System.get_env/0`). `file` is `nil` or a `%{kebab_key => raw}`
  map (already parsed). `flags` is a `%{kebab_key => raw}` map of command-line
  overrides. `db` is the in-database config source — a `%{kebab_key => string}`
  map read from `ALTER ROLE ... SET pgrst.*` (`Bier.CLI.DbSettings`); it beats
  env and file (PostgREST Config.hs `overrideFromDbOrEnvironment`:
  `dbConf <|> env`) but only for `db_settings_names/0` keys.
  """
  @spec load(map(), map() | nil, map(), map()) :: {:ok, map()} | {:error, String.t()}
  def load(env, file, flags, db \\ %{}) do
    file = file || %{}

    spec()
    |> Enum.reduce_while({:ok, %{}}, fn entry, {:ok, acc} ->
      case resolve(entry, env, file, flags, db) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, entry.key, value)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> put_app_settings(env, file)
    |> validate()
  end

  @app_settings_env_prefix "PGRST_APP_SETTINGS_"
  @app_settings_key_prefix "app.settings."

  # PostgREST folds PGRST_APP_SETTINGS_<NAME> env vars over the file's
  # app.settings.* entries, env winning per name (Config.hs parseAppSettings).
  # `normalize` only strips the PGRST_APP_SETTINGS_ prefix and prepends
  # "app.settings.", so the remainder is kept VERBATIM — no case folding
  # (case 1729). Values are kept as text — they end up as GUC values.
  defp put_app_settings({:error, _} = err, _env, _file), do: err

  defp put_app_settings({:ok, resolved}, env, file) do
    from_file =
      for {@app_settings_key_prefix <> name, value} <- file, name != "", into: %{} do
        {name, to_string(value)}
      end

    from_env =
      for {@app_settings_env_prefix <> name, value} <- env, name != "", into: %{} do
        {name, to_string(value)}
      end

    {:ok, Map.put(resolved, "app.settings", Map.merge(from_file, from_env))}
  end

  defp resolve(entry, env, file, flags, db) do
    case raw_source(entry, env, file, flags, db) do
      :absent ->
        {:ok, entry.default}

      {:present, raw} ->
        case coerce(entry.kind, raw) do
          # A wrong-typed/unparseable value coerces to :unset, which means
          # "fall back to the key's default" (PostgREST's wrong-type rule).
          {:ok, :unset} -> {:ok, entry.default}
          other -> other
        end
    end
  end

  # Precedence: flags > db > env > file, with PostgREST's alias semantics: each
  # spelling — canonical first, then deprecated aliases — is a complete source
  # that consults its own PGRST_* env var and then its file key. So
  # PGRST_DB_SCHEMA works like PostgREST's, and a canonical file key still
  # beats an alias env var (Config.hs optWithAlias wraps full parser arms).
  # Flags and the db source use canonical keys only (role settings carry the
  # canonical underscored name, see db_settings_names/0).
  defp raw_source(entry, env, file, flags, db) do
    db_value = if entry.key in @db_settable_keys, do: Map.get(db, entry.key)

    cond do
      present?(entry, Map.get(flags, entry.key)) ->
        {:present, Map.fetch!(flags, entry.key)}

      present?(entry, db_value) ->
        {:present, db_value}

      true ->
        Enum.find_value([entry.key | entry.aliases], :absent, fn key ->
          spelling_source(entry, key, env, file)
        end)
    end
  end

  defp spelling_source(entry, key, env, file) do
    env_var = env_var(key)

    cond do
      present?(entry, Map.get(env, env_var)) -> {:present, Map.fetch!(env, env_var)}
      present?(entry, Map.get(file, key)) -> {:present, Map.fetch!(file, key)}
      true -> nil
    end
  end

  # PostgREST derives every env var name from its key spelling: "PGRST_" plus
  # the uppercased key with dashes as underscores (Config.hs dashToUnderscore).
  defp env_var(key), do: "PGRST_" <> (key |> String.replace("-", "_") |> String.upcase())

  # nil/missing is absent. An empty string is absent for every kind EXCEPT
  # :csv_emptyable, where "" is a meaningful value (the empty list) — PostgREST's
  # splitOnCommasEmptyable (case 1728). Any other value is present.
  defp present?(_entry, nil), do: false
  defp present?(%{kind: :csv_emptyable}, ""), do: true
  defp present?(_entry, ""), do: false
  defp present?(_entry, _), do: true

  defp validate({:error, _} = err), do: err

  defp validate({:ok, resolved}) do
    with :ok <- run_validator(resolved, "jwt-secret", &Bier.Config.validate_jwt_secret/1),
         :ok <- run_validator(resolved, "jwt-aud", &Bier.Config.validate_jwt_aud/1),
         :ok <- validate_socket_mode(resolved, "server-unix-socket-mode"),
         :ok <- validate_socket_mode(resolved, "admin-server-unix-socket-mode"),
         :ok <- run_validator(resolved, "db-schemas", &Bier.Config.validate_db_schemas/1),
         :ok <-
           run_validator(resolved, "openapi-server-proxy-uri", &Bier.Config.validate_proxy_uri/1),
         :ok <- validate_secret_base64(resolved),
         {:ok, resolved} <- canonicalize_role_claim_key(resolved),
         :ok <- validate_admin_port(resolved) do
      {:ok, resolved}
    end
  end

  # Both socket-mode keys share PostgREST's parseSocketFileMode, which builds
  # its failure message from the key name (cases 1714/1715 and 1738).
  defp validate_socket_mode(resolved, key) do
    run_validator(resolved, key, &Bier.Config.validate_socket_mode(&1, key))
  end

  # jwt-secret-is-base64=true with an undecodable secret is fatal even for
  # `--dump-config` (case 1718). The decoded value is discarded here — the dump
  # prints the raw secret; the boot path decodes again inside Bier.Config.new/2.
  defp validate_secret_base64(resolved) do
    case {resolved["jwt-secret-is-base64"], resolved["jwt-secret"]} do
      {true, secret} when is_binary(secret) ->
        with {:ok, _decoded} <- Bier.Config.decode_base64_secret(secret), do: :ok

      _other ->
        :ok
    end
  end

  # jwt-role-claim-key parses as an RFC 9535 JSON Path (invalid is fatal, case
  # 1711) and is re-serialized in the canonical form aeson-jsonpath's dumpQuery
  # produces. The extra `--dump-config` escaping dumpJSPath applies on top of
  # that lives in `render_value/2`, because the escaped text is no longer a
  # re-parseable JSON Path and this value is also handed to `to_start_opts/1`.
  defp canonicalize_role_claim_key(resolved) do
    case RoleClaim.parse(resolved["jwt-role-claim-key"]) do
      {:ok, path} ->
        {:ok, Map.put(resolved, "jwt-role-claim-key", RoleClaim.dump(path))}

      {:error, _} = err ->
        err
    end
  end

  defp run_validator(resolved, key, fun) do
    case Map.get(resolved, key) do
      :unset -> :ok
      value -> fun.(value)
    end
  end

  # server-port has a default, so it is always an integer; admin-server-port
  # may be :unset. The rule itself (case 1717) lives in Bier.Config so the CLI
  # and Bier.start_link/1 reject identically.
  defp validate_admin_port(resolved) do
    Bier.Config.validate_admin_server_port(
      unset_to_nil(Map.get(resolved, "admin-server-port")),
      Map.get(resolved, "server-port")
    )
  end

  defp unset_to_nil(:unset), do: nil
  defp unset_to_nil(value), do: value

  @doc """
  Translate a resolved config map into a keyword list for `Bier.start_link/1`.
  `:unset` optional keys are omitted so Bier's own defaults apply. `db-uri` is
  parsed into discrete connection fields; `server-port` maps to `router[:port]`.
  """
  @spec to_start_opts(map()) :: keyword()
  def to_start_opts(resolved) do
    direct =
      [
        client_error_verbosity: resolved["client-error-verbosity"],
        db_schemas: resolved["db-schemas"],
        db_anon_role: resolved["db-anon-role"],
        db_extra_search_path: resolved["db-extra-search-path"],
        db_max_rows: resolved["db-max-rows"],
        pool_size: resolved["db-pool"],
        db_pool_max_idletime: resolved["db-pool-max-idletime"],
        db_prepared_statements: resolved["db-prepared-statements"],
        server_host: resolved["server-host"],
        server_unix_socket: resolved["server-unix-socket"],
        server_unix_socket_mode: resolved["server-unix-socket-mode"],
        openapi_server_proxy_uri: resolved["openapi-server-proxy-uri"],
        app_settings: Map.get(resolved, "app.settings", %{}),
        db_tx_end: bier_tx_end(resolved["db-tx-end"]),
        db_pre_request: resolved["db-pre-request"],
        db_root_spec: resolved["db-root-spec"],
        admin_server_port: resolved["admin-server-port"],
        jwt_secret: resolved["jwt-secret"],
        jwt_secret_is_base64: resolved["jwt-secret-is-base64"],
        jwt_aud: resolved["jwt-aud"],
        jwt_role_claim_key: resolved["jwt-role-claim-key"],
        jwt_cache_max_entries: resolved["jwt-cache-max-entries"],
        openapi_mode: resolved["openapi-mode"],
        openapi_security_active: resolved["openapi-security-active"],
        log_level: resolved["log-level"],
        log_query: resolved["log-query"],
        server_cors_allowed_origins: resolved["server-cors-allowed-origins"],
        db_plan_enabled: resolved["db-plan-enabled"],
        db_channel: resolved["db-channel"],
        db_channel_enabled: resolved["db-channel-enabled"],
        url_use_legacy_target_names: resolved["url-use-legacy-target-names"],
        server_trace_header: resolved["server-trace-header"],
        server_timing_enabled: resolved["server-timing-enabled"]
      ]
      |> Enum.reject(fn {_k, v} -> v == :unset end)

    router = [port: resolved["server-port"], scheme: :http]

    direct ++ [router: router] ++ db_uri_opts(resolved["db-uri"])
  end

  @doc """
  Like `to_start_opts/1`, but additionally runs the options through
  `Bier.Config.new/2` (Bier's full boot-time schema + semantic validators),
  returning `{:error, message}` instead of letting `Bier.start_link/1` raise.

  The parse layer deliberately accepts values Bier's schema rejects — e.g.
  `db-max-rows = 0` or a non-positive `server-port` (`:pos_integer` means ≥ 1)
  — because `--dump-config` must print whatever was parsed (conformance-pinned).
  Boot paths call this instead of `to_start_opts/1` so those values become a
  clean fatal message rather than a raised `MatchError`/`ArgumentError`.
  """
  @spec validated_start_opts(map()) :: {:ok, keyword()} | {:error, String.t()}
  def validated_start_opts(resolved) do
    opts = to_start_opts(resolved)

    case Bier.Config.new(opts, Bier.schema()) do
      {:ok, _conf} -> {:ok, opts}
      # NimbleOptions union-type errors span several lines; CLI fatals are
      # reported as one stderr line, so collapse the message's whitespace.
      {:error, message} -> {:error, String.replace(message, ~r/\s+/, " ")}
    end
  end

  @doc """
  Postgrex connection options for a resolved config: the parsed `db-uri`
  fields, with missing fields filled from the libpq-style `PG*` environment
  variables — PostgREST connects through libpq, which applies exactly these
  fallbacks — then `localhost`/`5432` defaults. Like libpq, a missing database
  name falls back to the user name.
  """
  @spec connection_opts(map(), map()) :: keyword()
  def connection_opts(resolved, env) do
    from_env =
      [
        hostname: env["PGHOST"],
        port: env_int(env["PGPORT"]),
        database: env["PGDATABASE"],
        username: env["PGUSER"],
        password: env["PGPASSWORD"]
      ]
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)

    from_env
    |> Keyword.merge(db_uri_opts(resolved["db-uri"]))
    |> Keyword.put_new(:hostname, "localhost")
    |> Keyword.put_new(:port, 5432)
    |> put_default_database()
  end

  defp put_default_database(opts) do
    case {opts[:database], opts[:username]} do
      {nil, user} when is_binary(user) -> Keyword.put(opts, :database, user)
      _ -> opts
    end
  end

  defp env_int(nil), do: nil

  defp env_int(s) do
    case Integer.parse(s) do
      {i, ""} -> i
      _ -> nil
    end
  end

  # Bier's runtime supports only :commit / :rollback. PostgREST's
  # *-allow-override variants (per-request Prefer override) collapse to their
  # base mode — the closest behavior Bier currently offers.
  defp bier_tx_end(v) when v in [:commit, :"commit-allow-override"], do: :commit
  defp bier_tx_end(v) when v in [:rollback, :"rollback-allow-override"], do: :rollback

  # Parse db-uri into Bier's discrete connection fields. Both libpq forms are
  # accepted: a URI ("postgresql://...") and a keyword/value conninfo string
  # ("host=... dbname=..."). An empty "postgresql://" carries no fields, so
  # Bier's defaults apply.
  defp db_uri_opts(uri) when uri in [nil, "", "postgresql://", "postgres://"], do: []

  defp db_uri_opts(uri) do
    if String.contains?(uri, "://"), do: uri_opts(uri), else: conninfo_opts(uri)
  end

  defp uri_opts(uri) do
    %URI{host: host, port: port, path: path, userinfo: userinfo, query: query} = URI.parse(uri)
    {user, pass} = split_userinfo(userinfo)
    database = path |> to_string() |> String.trim_leading("/") |> decode()

    [hostname: host, port: port, database: database, username: user, password: pass]
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
    |> Kernel.++(query_opts(query))
  end

  # Of the libpq URI query parameters only sslmode maps onto an option Bier
  # exposes; the others have no Postgrex counterpart here and are ignored.
  defp query_opts(nil), do: []
  defp query_opts(query), do: query |> URI.decode_query() |> Map.get("sslmode") |> sslmode_opts()

  # libpq's require/verify-* modes all encrypt the connection (certificate
  # verification beyond Postgrex's ssl defaults is not modeled); disable never
  # encrypts, and allow/prefer settle on plain TCP — the only non-retrying
  # behavior Postgrex offers.
  defp sslmode_opts(mode) when mode in ["require", "verify-ca", "verify-full"], do: [ssl: true]
  defp sslmode_opts(_mode), do: []

  # A libpq keyword/value conninfo string: whitespace-separated key=value
  # pairs. Single quotes around a value are stripped; libpq's full quoting
  # (spaces inside quotes, \' escapes) is not modeled. Only keys Bier maps
  # onto Postgrex options are consulted.
  defp conninfo_opts(conninfo) do
    pairs =
      for kv <- String.split(conninfo),
          [k, v] <- [String.split(kv, "=", parts: 2)],
          into: %{} do
        {k, String.trim(v, "'")}
      end

    [
      hostname: pairs["host"] || pairs["hostaddr"],
      port: conninfo_port(pairs["port"]),
      database: pairs["dbname"],
      username: pairs["user"],
      password: pairs["password"]
    ]
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
    |> Kernel.++(sslmode_opts(pairs["sslmode"]))
  end

  defp conninfo_port(nil), do: nil

  defp conninfo_port(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  # URI.parse/1 leaves percent-encoding intact, but Postgrex expects decoded
  # credentials/db name (a password is commonly encoded because `@`/`:` are URI
  # delimiters, e.g. `p%40ss` -> `p@ss`).
  defp split_userinfo(nil), do: {nil, nil}

  defp split_userinfo(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [user, pass] -> {decode(user), decode(pass)}
      [user] -> {decode(user), nil}
    end
  end

  defp decode(nil), do: nil
  defp decode(value), do: URI.decode(value)

  @doc """
  Render a resolved config map as PostgREST `--dump-config` text: one
  `key = value` line per spec key plus one per `app.settings.<name>` entry,
  sorted by key for determinism (so the output is reparse-stable).
  """
  @spec dump(map()) :: iodata()
  def dump(resolved) do
    {app_settings, keyed} = Map.pop(resolved, "app.settings", %{})

    app_settings
    |> Map.new(fn {name, value} -> {@app_settings_key_prefix <> name, value} end)
    |> Map.merge(keyed)
    |> Enum.sort()
    |> Enum.map(fn {key, value} -> [key, " = ", render_value(key, value), "\n"] end)
  end

  # PostgREST's dump table renders jwt-role-claim-key as `q . dumpJSPath`
  # (Config.hs): dumpJSPath escapes `"` -> `\"` and `$` -> `$$` (JSPath.hs) on
  # the canonical query text — the `$$` being the config-file escape for a
  # literal `$`, so the dump round-trips through a config file — and `q` then
  # quotes and escapes `"` a second time.
  defp render_value("jwt-role-claim-key", value) when is_binary(value) do
    value
    |> String.replace(~S("), ~S(\"))
    |> String.replace("$", "$$")
    |> quote_string()
  end

  defp render_value(_key, value), do: render(value)

  defp render(:unset), do: ~s("")
  defp render(value) when is_integer(value), do: Integer.to_string(value)
  defp render(true), do: "true"
  defp render(false), do: "false"
  defp render(value) when is_list(value), do: quote_string(Enum.join(value, ","))
  defp render(value) when is_atom(value), do: quote_string(Atom.to_string(value))
  defp render(value) when is_binary(value), do: quote_string(value)

  defp quote_string(s), do: [?", String.replace(s, ~S("), ~S(\")), ?"]
end
