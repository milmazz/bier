defmodule Bier.RequestLog do
  @moduledoc """
  Access-log formatting and the per-request SQL accumulator behind `log-level`
  and `log-query` (#28), mirroring PostgREST v14.12 `Logger.hs`.

  `should_log?/2` is upstream's `shouldLogResponse`: the configured level picks
  which *responses* get logged by status — `crit` none, `error` (the default)
  only ≥ 500, `warn` ≥ 400, `info`/`debug` everything.

  `access_line/3` renders the Apache-combined line PostgREST's WAI middleware
  emits (pinned by upstream's `test_io.py` log tests):

      - - <role> [<ts>] "GET /path HTTP/1.1" <status> <bytes> "<referer>" "<user-agent>"

  Host and ident are literal dashes; the user field is the resolved request
  role (including the anonymous role) or `-` when the request failed before
  role resolution. Timestamps are UTC (`+0000`) — PostgREST stamps the
  server's local zone, but Bier does not assume zone data is loadable.

  The accumulator collects the SQL a request executes (armed per request by
  `Bier.Plugs.Observability` only when `log-query` is on, so the hot path pays
  nothing otherwise). It is process-scoped like `Bier.ServerTiming`: the plug
  and the query sites run in the same request process, and re-arming clears
  leftovers from a previous request on a keep-alive connection.
  """

  @pdict_key :bier_request_log_sql

  # ---- log-level filter ----------------------------------------------------

  @doc "PostgREST Logger.hs `shouldLogResponse`: does `status` log at `level`?"
  @spec should_log?(:crit | :error | :warn | :info | :debug, integer() | nil) :: boolean()
  def should_log?(_level, nil), do: false
  def should_log?(:crit, _status), do: false
  def should_log?(:error, status), do: status >= 500
  def should_log?(:warn, status), do: status >= 400
  def should_log?(level, _status) when level in [:info, :debug], do: true

  # ---- access line ---------------------------------------------------------

  @doc "Render the Apache-combined access line for a sent response."
  @spec access_line(Plug.Conn.t(), String.t() | nil, DateTime.t()) :: String.t()
  def access_line(conn, role, %DateTime{} = now) do
    request = "#{conn.method} #{path_with_query(conn)} #{Plug.Conn.get_http_protocol(conn)}"

    Enum.join(
      [
        "- -",
        role || "-",
        "[#{Calendar.strftime(now, "%d/%b/%Y:%H:%M:%S +0000")}]",
        ~s("#{request}"),
        Integer.to_string(conn.status),
        Integer.to_string(IO.iodata_length(conn.resp_body || [])),
        ~s("#{first_header(conn, "referer")}"),
        ~s("#{first_header(conn, "user-agent")}")
      ],
      " "
    )
  end

  defp path_with_query(%{query_string: ""} = conn), do: conn.request_path
  defp path_with_query(conn), do: conn.request_path <> "?" <> conn.query_string

  defp first_header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [value | _rest] -> value
      [] -> ""
    end
  end

  # ---- per-request SQL accumulator (log-query) -----------------------------

  @doc """
  Arm (or disarm) SQL collection for the current request process, clearing any
  previous request's leftovers.
  """
  @spec arm(boolean()) :: :ok
  def arm(true) do
    Process.put(@pdict_key, [])
    :ok
  end

  def arm(false) do
    Process.delete(@pdict_key)
    :ok
  end

  @doc "Record an executed SQL statement. No-op unless the process is armed."
  @spec record(String.t()) :: :ok
  def record(sql) do
    case Process.get(@pdict_key) do
      nil -> :ok
      acc -> Process.put(@pdict_key, [sql | acc]) && :ok
    end

    :ok
  end

  @doc """
  Snapshot the accumulator for hand-off to another process (the cancellation
  task boundary, like `Bier.ServerTiming.export/0`). `nil` means disarmed.
  """
  @spec export() :: [String.t()] | nil
  def export, do: Process.get(@pdict_key)

  @doc "Adopt a snapshot produced by `export/0` in the current process."
  @spec restore([String.t()] | nil) :: :ok
  def restore(nil) do
    Process.delete(@pdict_key)
    :ok
  end

  def restore(acc) when is_list(acc) do
    Process.put(@pdict_key, acc)
    :ok
  end

  @doc "Return the recorded SQL in execution order and clear the accumulator."
  @spec drain() :: [String.t()]
  def drain do
    case Process.get(@pdict_key) do
      nil ->
        []

      acc ->
        Process.put(@pdict_key, [])
        Enum.reverse(acc)
    end
  end
end
