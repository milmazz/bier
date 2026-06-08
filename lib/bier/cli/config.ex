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

  @doc """
  Coerce a raw value (string from env/file, or already-typed from the file
  parser) to the typed value for `kind`. `:unset` marks an absent optional
  value (falls back to default). Enum mismatches return PostgREST's message.
  """
  @spec coerce(term(), term()) :: {:ok, term()} | {:error, String.t()}
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

  def coerce(:bool, v), do: {:ok, v in [true, "true", "1", 1]}

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
end
