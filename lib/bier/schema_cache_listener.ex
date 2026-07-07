defmodule Bier.SchemaCacheListener do
  @moduledoc """
  Subscribes to the instance's `db_channel` Postgres notification channel and
  reloads the schema cache on PostgREST's reload signals
  (`NOTIFY <db_channel>, 'reload schema'`).

  ## Payloads

  Mirroring PostgREST's listener:

    * `"reload schema"` — re-run the DB introspection and atomically swap the
      instance's `Bier.SchemaCache` snapshot;
    * `""` (empty) — PostgREST reloads schema cache *and* config; Bier's
      config is host-supplied, so only the schema cache is reloaded;
    * `"reload config"` — logged no-op (host applications own Bier's config);
    * anything else — ignored with a debug log.

  Bursts are coalesced: reload signals already queued in the mailbox are
  drained before a single reload runs, so a migration firing one NOTIFY per
  DDL statement causes one introspection, not N.

  ## Connection ownership

  The listener owns a dedicated `Postgrex.Notifications` connection (LISTEN
  cannot go through the request pool), started with `auto_reconnect: false`,
  and traps exits: when the connection drops — or cannot be established — the
  listener stays alive and retries with exponential backoff. A database
  outage therefore never crash-loops the instance's supervisor; reload
  signals just pause while the last good snapshot keeps serving.

  Notifications sent while disconnected are lost, so after every
  *re*-connect the listener reloads unconditionally to catch up (PostgREST
  does the same). Only a clean first *attempt* skips that reload — the boot
  introspection has just run. A first connect that only succeeds after a
  retry reloads like any other reconnect, since NOTIFYs could have fired
  during the failed attempts in between.

  A failed reload keeps the previous snapshot: `Bier.SchemaCache.reload/1`
  only swaps after a fully successful introspection.
  """

  use GenServer

  require Logger

  @initial_backoff 500
  @max_backoff 30_000

  def start_link(%Bier.Config{name: name} = conf) do
    GenServer.start_link(__MODULE__, conf, name: Bier.Registry.via(name, __MODULE__))
  end

  @impl GenServer
  def init(%Bier.Config{} = conf) do
    Process.flag(:trap_exit, true)

    state = %{
      conf: conf,
      notifications: nil,
      backoff: @initial_backoff,
      connected_before?: false
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, state), do: connect(state)

  @impl GenServer
  def handle_info(:connect, state), do: connect(state)

  def handle_info({:notification, _pid, _ref, _channel, payload}, state) do
    {:noreply, handle_payload(payload, state)}
  end

  def handle_info({:EXIT, pid, reason}, %{notifications: pid} = state) do
    Logger.warning(
      "Bier schema-cache listener for #{inspect(state.conf.name)} lost its " <>
        "LISTEN connection: #{inspect(reason)}"
    )

    {:noreply, schedule_reconnect(%{state | notifications: nil})}
  end

  # An EXIT from a process we no longer track (e.g. a connection already
  # replaced after an earlier failure) — nothing to do.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  # The LISTEN connection cannot go through the request pool, so the listener
  # runs its own single Postgrex.Notifications connection built from the same
  # instance options.
  defp connect(%{conf: conf} = state) do
    opts =
      conf
      |> Bier.postgrex_opts()
      |> Keyword.drop([:name, :pool_size])
      |> Keyword.merge(sync_connect: true, auto_reconnect: false)

    case Postgrex.Notifications.start_link(opts) do
      {:ok, pid} ->
        case safe_listen(pid, conf.db_channel) do
          {:ok, _ref} ->
            # Notifications sent while we were down are lost — after a
            # REconnect (including a first connect that only succeeded on
            # retry), reload unconditionally to catch up. Only a clean
            # first-attempt connect skips it: the boot introspection just ran.
            if state.connected_before? or state.backoff != @initial_backoff do
              reload(conf.name)
            end

            {:noreply,
             %{state | notifications: pid, backoff: @initial_backoff, connected_before?: true}}

          other ->
            Logger.warning(
              "Bier schema-cache listener for #{inspect(conf.name)} could not " <>
                "LISTEN on #{inspect(conf.db_channel)} (retrying in " <>
                "#{state.backoff}ms): #{inspect(other)}"
            )

            # Not a real subscription (an async connect not up yet, or the
            # fresh connection died in the window before the LISTEN) — drop
            # it and retry. We stay linked and do NOT touch
            # `state.notifications`: a late `:EXIT` from this pid still
            # lands on the catch-all clause below and is ignored.
            stop_connection(pid)
            {:noreply, schedule_reconnect(state)}
        end

      {:error, reason} ->
        Logger.warning(
          "Bier schema-cache listener for #{inspect(conf.name)} cannot reach " <>
            "the database (retrying in #{state.backoff}ms): #{inspect(reason)}"
        )

        {:noreply, schedule_reconnect(state)}
    end
  end

  # `listen/3` returns `{:ok, ref}` once subscribed, or `{:eventually, ref}`
  # when the connection isn't actually up yet — not a real subscription
  # either. It can also raise if the fresh connection died in the window
  # between `start_link/1` returning and this call; caught here so a lost
  # race becomes a retry instead of crashing the listener.
  defp safe_listen(pid, channel) do
    Postgrex.Notifications.listen(pid, channel)
  catch
    :exit, reason -> {:exit, reason}
  end

  # `Process.exit/2` is a no-op if the pid is already dead, so this is safe
  # to call unconditionally in the failure branch above.
  defp stop_connection(pid), do: Process.exit(pid, :kill)

  defp schedule_reconnect(state) do
    Process.send_after(self(), :connect, state.backoff)
    %{state | backoff: min(state.backoff * 2, @max_backoff)}
  end

  # PostgREST semantics: "reload schema" reloads the schema cache; an empty
  # payload means "reload schema cache AND config" — the config half is a
  # no-op here, so both trigger the same schema reload.
  defp handle_payload(payload, state) when payload in ["reload schema", ""] do
    drain_reload_signals()
    reload(state.conf.name)
    state
  end

  defp handle_payload("reload config", state) do
    Logger.info(
      "Bier received 'reload config' on #{inspect(state.conf.db_channel)}: " <>
        "ignored — Bier's config is supplied by the host application"
    )

    state
  end

  defp handle_payload(other, state) do
    Logger.debug(
      "Bier ignoring unknown payload on #{inspect(state.conf.db_channel)}: #{inspect(other)}"
    )

    state
  end

  # Coalesce bursts: consume every reload signal already queued so N
  # back-to-back NOTIFYs cause one introspection run, not N.
  defp drain_reload_signals do
    receive do
      {:notification, _pid, _ref, _channel, payload}
      when payload in ["reload schema", ""] ->
        drain_reload_signals()
    after
      0 -> :ok
    end
  end

  defp reload(name) do
    case Bier.SchemaCache.reload(name) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Bier schema-cache reload for #{inspect(name)} failed; keeping the " <>
            "previous snapshot: #{inspect(reason)}"
        )
    end
  end
end
