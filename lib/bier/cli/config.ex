defmodule Bier.CLI.Config do
  @moduledoc """
  The PostgREST config dialect ↔ Bier boundary.

  `spec/0` is the single source of truth: one entry per PostgREST config key
  that Bier implements, carrying its `PGRST_*` env var, deprecated aliases,
  value type, and PostgREST default (used for `--dump-config`). Keys Bier does
  not implement are intentionally absent — their conformance cases stay
  deferred.
  """

  # kind:
  #   :string | :opt_string | :int | :opt_int | :bool
  #   :csv | :csv_emptyable
  #   {:enum_atom, name} | {:enum_str, name}
  # default: the PostgREST default, rendered by dump/1 when unset.
  @entries [
    %{key: "db-uri", env: "PGRST_DB_URI", kind: :string, default: "postgresql://", aliases: []},
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
    %{
      key: "admin-server-port",
      env: "PGRST_ADMIN_SERVER_PORT",
      kind: :opt_int,
      default: :unset,
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
    }
  }

  @doc "The config key spec table (one entry per implemented PostgREST key)."
  @spec spec() :: [map()]
  def spec, do: @entries

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

  # Mirrors PostgREST's coerceBool: case-insensitive "true" and any positive
  # integer (as a string or number) are truthy; everything else is false.
  def coerce(:bool, v) when is_boolean(v), do: {:ok, v}

  def coerce(:bool, v) when is_integer(v), do: {:ok, v > 0}

  def coerce(:bool, v) do
    s = v |> to_string() |> String.downcase()

    truthy =
      s == "true" or
        match?({n, ""} when n > 0, Integer.parse(s))

    {:ok, truthy}
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
  Resolve every spec key from flags > env > file > default, applying aliases and
  coercion, then run the shared semantic validators. Returns the resolved
  `%{kebab_key => typed_value}` map, or `{:error, message}` on a fatal problem.

  `env` is a `%{"PGRST_*" => string}` map (the caller supplies it — the core
  never reads `System.get_env/0`). `file` is `nil` or a `%{kebab_key => raw}`
  map (already parsed). `flags` is a `%{kebab_key => raw}` map of command-line
  overrides.
  """
  @spec load(map(), map() | nil, map()) :: {:ok, map()} | {:error, String.t()}
  def load(env, file, flags) do
    file = file || %{}

    spec()
    |> Enum.reduce_while({:ok, %{}}, fn entry, {:ok, acc} ->
      case resolve(entry, env, file, flags) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, entry.key, value)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> validate()
  end

  defp resolve(entry, env, file, flags) do
    case raw_source(entry, env, file, flags) do
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

  # Precedence: flags > env > file, with PostgREST's alias semantics: each
  # spelling — canonical first, then deprecated aliases — is a complete source
  # that consults its own PGRST_* env var and then its file key. So
  # PGRST_DB_SCHEMA works like PostgREST's, and a canonical file key still
  # beats an alias env var (Config.hs optWithAlias wraps full parser arms).
  # Flags use canonical keys only.
  defp raw_source(entry, env, file, flags) do
    if present?(entry, Map.get(flags, entry.key)) do
      {:present, Map.fetch!(flags, entry.key)}
    else
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
         :ok <- validate_admin_port(resolved) do
      {:ok, resolved}
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
        db_schemas: resolved["db-schemas"],
        db_anon_role: resolved["db-anon-role"],
        db_extra_search_path: resolved["db-extra-search-path"],
        db_max_rows: resolved["db-max-rows"],
        db_tx_end: bier_tx_end(resolved["db-tx-end"]),
        db_pre_request: resolved["db-pre-request"],
        db_root_spec: resolved["db-root-spec"],
        admin_server_port: resolved["admin-server-port"],
        jwt_secret: resolved["jwt-secret"],
        jwt_aud: resolved["jwt-aud"],
        openapi_mode: resolved["openapi-mode"],
        openapi_security_active: resolved["openapi-security-active"],
        log_level: resolved["log-level"],
        server_cors_allowed_origins: resolved["server-cors-allowed-origins"],
        db_plan_enabled: resolved["db-plan-enabled"],
        db_channel: resolved["db-channel"],
        db_channel_enabled: resolved["db-channel-enabled"],
        server_trace_header: resolved["server-trace-header"],
        server_timing_enabled: resolved["server-timing-enabled"]
      ]
      |> Enum.reject(fn {_k, v} -> v == :unset end)

    router = [port: resolved["server-port"], scheme: :http]

    direct ++ [router: router] ++ db_uri_opts(resolved["db-uri"])
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
  `key = value` line per spec key, sorted by key for determinism (so the output
  is reparse-stable).
  """
  @spec dump(map()) :: iodata()
  def dump(resolved) do
    spec()
    |> Enum.map(& &1.key)
    |> Enum.sort()
    |> Enum.map(fn key -> [key, " = ", render(Map.fetch!(resolved, key)), "\n"] end)
  end

  defp render(:unset), do: ~s("")
  defp render(value) when is_integer(value), do: Integer.to_string(value)
  defp render(true), do: "true"
  defp render(false), do: "false"
  defp render(value) when is_list(value), do: quote_string(Enum.join(value, ","))
  defp render(value) when is_atom(value), do: quote_string(Atom.to_string(value))
  defp render(value) when is_binary(value), do: quote_string(value)

  defp quote_string(s), do: [?", String.replace(s, ~S("), ~S(\")), ?"]
end
