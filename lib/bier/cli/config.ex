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

  # Precedence: flags > env > file. Aliases are consulted for file keys only
  # (PostgREST aliases are file/env spellings; flags use canonical keys).
  defp raw_source(entry, env, file, flags) do
    cond do
      present?(entry, Map.get(flags, entry.key)) -> {:present, Map.fetch!(flags, entry.key)}
      present?(entry, Map.get(env, entry.env)) -> {:present, Map.fetch!(env, entry.env)}
      true -> file_source(entry, file)
    end
  end

  defp file_source(entry, file) do
    keys = [entry.key | entry.aliases]

    case Enum.find(keys, fn k -> present?(entry, Map.get(file, k)) end) do
      nil -> :absent
      key -> {:present, Map.fetch!(file, key)}
    end
  end

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

  # admin-server-port must differ from server-port (case 1717). server-port has
  # a default, so it is always an integer; admin-server-port may be :unset.
  defp validate_admin_port(resolved) do
    case {Map.get(resolved, "admin-server-port"), Map.get(resolved, "server-port")} do
      {port, port} when is_integer(port) ->
        {:error, "admin-server-port cannot be the same as server-port"}

      _ ->
        :ok
    end
  end

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
        log_level: resolved["log-level"],
        server_cors_allowed_origins: resolved["server-cors-allowed-origins"],
        db_plan_enabled: resolved["db-plan-enabled"],
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

  # Parse a libpq URI into Bier's discrete connection fields. An empty
  # "postgresql://" carries no fields, so Bier's defaults apply.
  defp db_uri_opts(uri) when uri in [nil, "", "postgresql://", "postgres://"], do: []

  defp db_uri_opts(uri) do
    %URI{host: host, port: port, path: path, userinfo: userinfo} = URI.parse(uri)
    {user, pass} = split_userinfo(userinfo)
    database = path |> to_string() |> String.trim_leading("/") |> decode()

    [hostname: host, port: port, database: database, username: user, password: pass]
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
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
