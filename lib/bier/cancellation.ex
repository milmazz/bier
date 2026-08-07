defmodule Bier.Cancellation do
  @moduledoc """
  Cancels the in-flight Postgres query when the HTTP client disconnects (#82).

  PostgREST cannot do this (postgrest#699, open since 2016): an accidental
  unfiltered `DELETE` keeps running server-side after the client kills the
  request. On the BEAM the disconnect is observable, so Bier ties it to a real
  backend cancel:

    1. The request's database work runs in a `Task` linked to the connection
       process, while the connection process arms the request socket
       (`active: :once`) and waits for either the task result or a socket
       close notification.
    2. On disconnect the task is killed. `DBConnection` sees its client die
       mid-checkout and disconnects the connection, and Postgrex's protocol
       disconnect sends a wire `CancelRequest` (with the backend key) before
       closing — the PostgreSQL backend aborts the query instead of running it
       to completion, and the pool slot is re-established clean.
    3. `[:bier, :query, :cancelled]` is emitted (see `Bier.Telemetry`) and the
       request falls through to `Bier.Plugs.FallbackController` as
       `{:error, :client_disconnected}` (a 499 nobody will receive, kept for
       request telemetry/logging symmetry).

  ## Scope and limitations

    * Disconnect detection watches the raw HTTP/1 socket (Bandit /
      ThousandIsland, TCP and SSL). Any other adapter shape falls back to
      running the work inline, exactly as before this module existed.
    * The request body is fully read (`Bier.Plugs.ReadBody`) before any query
      runs, so bytes arriving mid-query are only possible from a pipelining
      client. Such bytes are consumed by the watcher (they cannot be pushed
      back) and watching stops for that request — a non-issue for REST API
      clients, which do not pipeline.
  """

  alias ThousandIsland.Socket

  @doc """
  Run `fun` (a zero-arity function performing the request's database work),
  cancelling it if the HTTP client disconnects while it is in flight.

  Returns `fun`'s result, or `{:error, :client_disconnected}` after a
  disconnect-triggered cancel. Raises/throws/exits from `fun` propagate
  unchanged (same class, reason, and stacktrace) so error semantics are
  identical to calling `fun` directly.
  """
  @spec run(Plug.Conn.t(), map(), (-> result)) :: result | {:error, :client_disconnected}
        when result: term()
  def run(conn, config, fun) when is_function(fun, 0) do
    with true <- Map.get(config, :cancel_on_disconnect, true),
         {:ok, raw} <- watchable_socket(conn) do
      run_watched(raw, config, fun)
    else
      _opted_out_or_unsupported -> fun.()
    end
  end

  # The raw socket to watch for close notifications. Only the Bandit HTTP/1
  # adapter exposes one (`conn.adapter` carries the transport's
  # `ThousandIsland.Socket`); HTTP/2 streams and test adapters do not — and
  # HTTP/2 needs none: Bandit kills the stream process on client reset, which
  # kills the linked task and triggers the same DBConnection cancel path.
  defp watchable_socket(%Plug.Conn{
         adapter: {_mod, %{transport: %{socket: %Socket{socket: raw, transport_module: tm}}}}
       })
       when tm in [ThousandIsland.Transports.TCP, ThousandIsland.Transports.SSL],
       do: {:ok, raw}

  defp watchable_socket(_conn), do: :unsupported

  defp run_watched(raw, config, fun) do
    # Server-Timing phases are accumulated in the process dictionary of
    # whichever process runs the work (`Bier.ServerTiming`), so the task
    # adopts the request's accumulator and hands it back with the result.
    timing = Bier.ServerTiming.export()

    task =
      Task.async(fn ->
        Bier.ServerTiming.restore(timing)

        try do
          {:ok, fun.(), Bier.ServerTiming.export()}
        catch
          kind, reason -> {:caught, kind, reason, __STACKTRACE__, Bier.ServerTiming.export()}
        end
      end)

    # `setopts` failing means the socket is already closed/errored — the
    # client is gone before the query even settled in; cancel immediately.
    case arm(raw) do
      :ok -> await(task, raw, config)
      {:error, _reason} -> cancelled(task, config)
    end
  end

  defp await(%Task{ref: ref} = task, raw, config) do
    receive do
      {^ref, result} ->
        Process.demonitor(ref, [:flush])
        _ = disarm(raw)
        unwrap(result)

      {:DOWN, ^ref, :process, _pid, reason} ->
        # The task was killed out-of-band; mirror `Task.await/2`.
        exit({reason, {__MODULE__, :await, [task]}})

      {closed, ^raw} when closed in [:tcp_closed, :ssl_closed] ->
        cancelled(task, config)

      {error, ^raw, _reason} when error in [:tcp_error, :ssl_error] ->
        cancelled(task, config)

      {data, ^raw, _bytes} when data in [:tcp, :ssl] ->
        # Pipelined bytes (see moduledoc). `active: :once` already reverted
        # the socket to passive, so just keep waiting for the task.
        await(task, raw, config)
    end
  end

  defp cancelled(task, config) do
    # Killing the task (the DBConnection client) makes the pool disconnect
    # its connection; Postgrex's disconnect sends the wire CancelRequest.
    Task.shutdown(task, :brutal_kill)
    Bier.Telemetry.query_cancelled(%{instance: config.name})
    {:error, :client_disconnected}
  end

  defp unwrap({:ok, result, timing}) do
    Bier.ServerTiming.restore(timing)
    result
  end

  defp unwrap({:caught, kind, reason, stacktrace, timing}) do
    Bier.ServerTiming.restore(timing)
    :erlang.raise(kind, reason, stacktrace)
  end

  defp arm({:sslsocket, _, _} = raw), do: :ssl.setopts(raw, active: :once)
  defp arm(raw), do: :inet.setopts(raw, active: :once)

  defp disarm({:sslsocket, _, _} = raw), do: :ssl.setopts(raw, active: false)
  defp disarm(raw), do: :inet.setopts(raw, active: false)
end
