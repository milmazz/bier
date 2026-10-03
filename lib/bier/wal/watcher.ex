defmodule Bier.Wal.Watcher do
  @moduledoc """
  Notices when `Bier.Wal.Supervisor` gives up, and makes the stopped feed
  explicit instead of silent.

  The WAL supervisor is `restart: :temporary` (see its `child_spec/1`), so
  once it exhausts its own restart budget the instance supervisor simply
  deletes it: no restart, no error, and — Elixir's Logger drops SASL
  supervisor reports by default — nothing in the log. Left at that, every
  live table subscriber would sit on a stream that can never deliver again,
  new table subscriptions would be accepted into the same silence, and a
  `Last-Event-ID` resume would find no Buffer at all.

  This process monitors the WAL supervisor and, when it goes down:

  1. marks the feed stopped (`Bier.Wal.feed_stopped?/1`), so the events
     endpoint refuses new `table=` subscriptions and resumes with
     `503 BIER004` before streaming;
  2. logs the give-up at error level and emits
     `[:bier, :wal, :feed, :stopped]`;
  3. tells every live table subscriber, which ends its stream with
     `event: bier:closed` / `{"reason":"feed_stopped"}`.

  The flag is set BEFORE subscribers are told, and a new subscriber checks
  it again AFTER registering (`Bier.Events`), so a subscription racing the
  give-up either registered in time to be told or sees the flag — it cannot
  slip between the two and wait forever.

  A monitor in a separate process, rather than `terminate/2` with
  `trap_exit` in the WAL supervisor's own children: a child's `terminate/2`
  runs with reason `:shutdown` both when the supervisor gives up and when
  the instance is stopped normally, so it cannot tell the two apart. This
  process can: it starts AFTER the WAL supervisor and is therefore stopped
  BEFORE it on an orderly shutdown (children stop in reverse start order),
  so the only way it ever sees the WAL supervisor go down is a give-up.
  """

  use GenServer

  require Logger

  alias Bier.Registry

  def start_link(%Bier.Config{} = conf) do
    GenServer.start_link(__MODULE__, conf, name: Registry.via(conf.name, __MODULE__))
  end

  @impl true
  def init(%Bier.Config{name: name}) do
    case GenServer.whereis(Registry.via(name, Bier.Wal.Supervisor)) do
      pid when is_pid(pid) ->
        # A fresh instance (or a restart of this process while the feed is
        # alive): clear any flag a previous instance of the same name left.
        Bier.Wal.mark_feed_running(name)
        {:ok, %{name: name, ref: Process.monitor(pid)}}

      nil ->
        # Restarted after the give-up already happened (this process
        # crashed afterwards): the feed is gone for this instance's life.
        # Announce only if nobody has yet — the flag says whether they did.
        unless Bier.Wal.feed_stopped?(name), do: feed_stopped(name, :noproc)
        {:ok, %{name: name, ref: nil}}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{ref: ref} = state) do
    feed_stopped(state.name, reason)
    {:noreply, %{state | ref: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp feed_stopped(name, reason) do
    # Flag first, then announce — see the moduledoc on the ordering.
    Bier.Wal.mark_feed_stopped(name)

    {max_restarts, max_seconds} = Bier.Wal.Supervisor.budget()

    Logger.error(
      "Bier WAL change feed for #{inspect(name)} stopped: its supervisor exceeded its " <>
        "restart budget (#{max_restarts} restarts in #{max_seconds}s) and was not restarted. " <>
        "The HTTP API keeps serving; table subscriptions are closed and new ones are " <>
        "refused with 503 BIER004. Restart the Bier instance to bring the feed back."
    )

    Bier.Telemetry.wal_feed_stopped(%{instance: name, reason: reason})

    for pid <- Bier.Events.Registry.table_subscribers(name),
        do: send(pid, :bier_wal_feed_stopped)

    :ok
  end
end
