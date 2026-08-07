defmodule Bier.CLI.DbSettings do
  @moduledoc """
  The in-database config source (PostgREST `Config/Database.hs`
  `queryDbSettings`): reads `pgrst.*` settings from
  `pg_catalog.pg_db_role_setting` for the connecting role — cluster-wide and
  current-database-specific, the latter winning — filtered to the
  `Bier.CLI.Config.db_settings_names/0` whitelist, and returns them as a
  `%{kebab_key => raw_string}` map for `Bier.CLI.Config.load/4`'s `db` source.
  """

  alias Bier.CLI.Config

  # Upstream's query minus its db_pre_config UNION arm (Bier does not
  # implement pre-config functions).
  @query """
  WITH
  role_setting AS (
    SELECT setdatabase as database,
           unnest(setconfig) as setting
    FROM pg_catalog.pg_db_role_setting
    WHERE setrole = quote_ident(CURRENT_USER)::regrole::oid
      AND setdatabase IN (0, (SELECT oid FROM pg_catalog.pg_database WHERE datname = CURRENT_CATALOG))
  ),
  kv_settings AS (
    SELECT database,
           substr(setting, 1, strpos(setting, '=') - 1) as k,
           substr(setting, strpos(setting, '=') + 1) as v
    FROM role_setting
  )
  SELECT DISTINCT ON (key)
         replace(k, 'pgrst.', '') AS key,
         v AS value
  FROM kv_settings
  WHERE k = ANY($1) AND v IS NOT NULL
  ORDER BY key, database DESC NULLS LAST
  """

  @doc """
  Connect with the resolved `db-uri` (plus `PG*` fallbacks, see
  `Bier.CLI.Config.connection_opts/2`), read the role settings, and return
  them keyed by kebab config key. Connection or query failures come back as
  `{:error, message}` for the CLI's fatal-error path.
  """
  @spec fetch(map(), map()) :: {:ok, map()} | {:error, String.t()}
  def fetch(resolved, env) do
    opts = Config.connection_opts(resolved, env) ++ [pool_size: 1]

    case Postgrex.start_link(opts) do
      {:ok, conn} ->
        try do
          run_query(conn)
        after
          GenServer.stop(conn)
        end

      {:error, reason} ->
        {:error, "in-database config (db-config): #{inspect(reason)}"}
    end
  rescue
    # A config missing required connection fields (e.g. no database name and
    # no username to fall back to) raises in Postgrex.start_link.
    e in ArgumentError ->
      {:error, "in-database config (db-config): " <> Exception.message(e)}
  end

  defp run_query(conn) do
    case Postgrex.query(conn, @query, [Config.db_settings_names()]) do
      {:ok, %Postgrex.Result{rows: rows}} ->
        {:ok, Map.new(rows, fn [k, v] -> {String.replace(k, "_", "-"), v} end)}

      {:error, err} ->
        {:error, "in-database config (db-config): " <> Exception.message(err)}
    end
  end
end
