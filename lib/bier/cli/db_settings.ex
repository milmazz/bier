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

  # This read runs on a pool of one opened just for it, so a database that is
  # momentarily out of connection slots makes `DBConnection` drop the checkout
  # as backpressure (a `DBConnection.ConnectionError`) before the connection is
  # ever established. That is a client-side artifact, not a configuration
  # error, and PostgREST does not fail on it either — it reads the settings
  # over the app pool, whose acquisition is retried. So a dropped checkout is
  # retried until the deadline; only then does it become the CLI's fatal error.
  # The narrow queue window drops each attempt after ~1s instead of the ~4-6s
  # a default-tuned pool waits, so the deadline spends its budget on ~10 tries
  # rather than one long unattended wait; the budget itself is PostgREST's
  # `db-pool-acquisition-timeout` default. Postgres errors (a revoked
  # privilege, say) are answered immediately — they will not fix themselves.
  @queue_opts [queue_target: 50, queue_interval: 500]
  @acquire_deadline_ms 10_000
  @acquire_pause_ms 100

  # The drop itself cannot tell "busy" from "not there": a pool holding no live
  # connection queues the checkout either way, so an unreachable server and a
  # slot-starved one both arrive as the same `reason: :queue_timeout` error with
  # the same message. Classify the endpoint up front instead. A socket that is
  # refused, unroutable, or never answers is fatal immediately — it will not fix
  # itself within the deadline, and making the CLI sit silent for it is the
  # worst answer to the most common misconfiguration (wrong port, server not
  # started). A server that is merely out of connection slots *accepts* the
  # socket and rejects later, at the startup packet (`53300`), so it still
  # reaches the retry above — which is the case the retry exists for.
  @probe_timeout_ms 2_000

  @doc false
  @spec acquire_deadline_ms() :: pos_integer()
  def acquire_deadline_ms, do: @acquire_deadline_ms

  # The connection options this read adds on top of
  # Bier.CLI.Config.connection_opts/2, all derived from @acquire_deadline_ms so
  # the budget and the transport timeouts cannot drift apart (#149).
  #
  # An endpoint that *accepts* the socket but never completes the startup
  # packet (a stale port-forward, a wrong-service port, a Postgres wedged
  # before the startup packet) is the case that escapes: the TCP probe passes,
  # so it reaches Postgrex. Three separate defaults each overshot the budget
  # there, and all three have to be pinned:
  #
  #   * :timeout (15s) is what Postgrex derives connect/handshake from when
  #     they are unset — and it alone governs the TLS handshake and the query
  #     itself, so setting only the other two still leaves an unbounded path.
  #   * :connect_timeout and :handshake_timeout run serially per endpoint
  #     (connect/3 then handshake/3, each with its own timer), so each gets
  #     half the budget rather than all of it.
  #   * :shutdown — a connection wedged mid-handshake ignores a graceful stop
  #     until its own timer fires, so the GenServer.stop/1 in connect_and_read/1
  #     would sit on it, capped only by the pool supervisor's 5s child
  #     shutdown. That teardown, not the wait, is what actually spent the extra
  #     time: the retry loop was already giving up on schedule.
  @doc false
  @spec acquire_opts() :: keyword()
  def acquire_opts do
    half = div(@acquire_deadline_ms, 2)

    [
      pool_size: 1,
      timeout: @acquire_deadline_ms,
      connect_timeout: half,
      handshake_timeout: half,
      shutdown: :brutal_kill
    ] ++ @queue_opts
  end

  # Keyword.merge, not ++: later keys win, so the acquisition bounds always
  # beat anything connection_opts/2 resolves from db-uri query params. With
  # ++ a future libpq connect_timeout mapping would silently outrank them.
  @doc false
  @spec connect_opts(map(), map()) :: keyword()
  def connect_opts(resolved, env) do
    Keyword.merge(Config.connection_opts(resolved, env), acquire_opts())
  end

  @doc """
  Connect with the resolved `db-uri` (plus `PG*` fallbacks, see
  `Bier.CLI.Config.connection_opts/2`), read the role settings, and return
  them keyed by kebab config key. Connection or query failures come back as
  `{:error, message}` for the CLI's fatal-error path: an endpoint nothing is
  listening on fails at once, while a connection the pool could not hand out in
  time is retried to the acquisition deadline first.
  """
  @spec fetch(map(), map()) :: {:ok, map()} | {:error, String.t()}
  def fetch(resolved, env) do
    opts = connect_opts(resolved, env)

    with :ok <- probe(opts) do
      connect_and_read(opts)
    end
  rescue
    # A config missing required connection fields (e.g. no database name and
    # no username to fall back to) raises in Postgrex.start_link.
    e in ArgumentError ->
      {:error, "in-database config (db-config): " <> Exception.message(e)}
  end

  # Is anything listening on the resolved endpoint? `Config.connection_opts/2`
  # always resolves a hostname and port (defaulting to localhost:5432) and
  # never emits Postgrex's `:socket`/`:socket_dir`, so this is a well-defined
  # TCP check. That coupling is why unix-socket support would have to teach
  # this probe about `{:local, path}` (or skip it) rather than let it reject a
  # good socket configuration before Postgrex sees it — see #146.
  defp probe(opts) do
    host = to_charlist(opts[:hostname])

    case :gen_tcp.connect(host, opts[:port], [:binary, active: false], @probe_timeout_ms) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, reason} ->
        {:error,
         "in-database config (db-config): could not connect to " <>
           "#{opts[:hostname]}:#{opts[:port]} (#{inspect(reason)})"}
    end
  end

  defp connect_and_read(opts) do
    case Postgrex.start_link(opts) do
      {:ok, conn} ->
        try do
          run_query(conn, System.monotonic_time(:millisecond))
        after
          GenServer.stop(conn)
        end

      {:error, reason} ->
        {:error, "in-database config (db-config): #{inspect(reason)}"}
    end
  end

  defp run_query(conn, started_at) do
    case Postgrex.query(conn, @query, [Config.db_settings_names()]) do
      {:ok, %Postgrex.Result{rows: rows}} ->
        {:ok, Map.new(rows, fn [k, v] -> {String.replace(k, "_", "-"), v} end)}

      {:error, %DBConnection.ConnectionError{} = err} ->
        retry_or_fail(conn, started_at, err)

      {:error, err} ->
        {:error, error_message(err)}
    end
  end

  defp retry_or_fail(conn, started_at, err) do
    if elapsed_ms(started_at) < @acquire_deadline_ms do
      Process.sleep(@acquire_pause_ms)
      run_query(conn, started_at)
    else
      {:error, gave_up_message(started_at, err)}
    end
  end

  defp elapsed_ms(started_at), do: System.monotonic_time(:millisecond) - started_at

  # The underlying DBConnection error reports how long the *last* checkout sat
  # in the queue — about a second — which understates a ten-second wait by an
  # order of magnitude. Lead with the time actually spent and the budget it was
  # spent against, then the error that ended it.
  defp gave_up_message(started_at, err) do
    "in-database config (db-config): gave up after #{elapsed_ms(started_at)}ms " <>
      "(db-pool-acquisition-timeout #{@acquire_deadline_ms}ms); last error: " <>
      Exception.message(err)
  end

  defp error_message(err), do: "in-database config (db-config): " <> Exception.message(err)
end
