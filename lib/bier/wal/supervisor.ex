defmodule Bier.Wal.Supervisor do
  @moduledoc """
  Supervises one instance's WAL change feed: `Bier.Wal.Buffer`, then
  `Bier.Wal.Consumer`, under `:rest_for_one`.

  The pair has its own supervisor so that its failures stay its own. Under
  the instance supervisor directly, every consumer crash was charged to the
  budget that also covers the Postgrex pool and the HTTP server — a fourth
  crash within five seconds (one more than OTP's default intensity of 3 in
  5s) took the whole instance down, turning a WAL-feed problem into an API
  outage. Here they spend this supervisor's budget instead, and when that
  runs out only the feed stops (see `child_spec/1`).

  `:rest_for_one` because the Consumer depends on the Buffer and not the
  other way round. A Buffer crash takes its history and generation counter
  with it; restarting the Consumer alongside means the fresh slot bumps the
  fresh Buffer's generation and every live subscriber is told
  `stream_restarted`. Under the old `:one_for_one` the Consumer's next
  `append` simply succeeded against the fresh, empty Buffer, so live
  subscribers never learned that history had vanished (only an append that
  landed in the instant the Buffer was down hit `retain/2`'s catch and
  announced `history_evicted` for its tables — which can still happen here,
  just before the restart's `stream_restarted`). A Consumer crash restarts
  the Consumer alone; the Buffer
  survives it, and the restarted Consumer's generation bump invalidates the
  old history the ordinary way.

  `init/1` also runs `Bier.Wal.validate!/2` before either child starts, so a
  misconfigured feed (`wal_level`, a missing publication, a role without
  `REPLICATION`) still fails the instance's boot with its remediation
  message before the consumer could ever flap against it.
  """

  use Supervisor

  alias Bier.Registry

  # This supervisor's own budget. Not the OTP default (3 in 5s): the
  # consumer is built not to crash on anything transient — auto_reconnect
  # covers connection loss, slot creation retries on a backoff, an
  # unavailable Buffer is caught — so a crash is a bug, and a burst of a
  # few is worth riding out. But every restart pushes `stream_restarted` to
  # every subscriber, and the client contract answers each with a fresh
  # bootstrapping GET, so a sustained crash loop is a request storm against
  # the very API this isolation protects. Five in thirty seconds tolerates a
  # burst and gives up on anything that keeps crashing more often than once
  # every six seconds.
  @max_restarts 5
  @max_seconds 30

  @doc "This supervisor's restart budget, as `{max_restarts, max_seconds}`."
  @spec budget() :: {pos_integer(), pos_integer()}
  def budget, do: {@max_restarts, @max_seconds}

  def start_link(%Bier.Config{} = conf) do
    Supervisor.start_link(__MODULE__, conf, name: Registry.via(conf.name, __MODULE__))
  end

  @doc """
  `restart: :temporary` — when this supervisor exhausts its budget, the
  instance supervisor does NOT restart it.

  Restarting it would hand the failure straight back to the instance
  supervisor's budget, which is exactly the coupling this module exists to
  break: a deterministic crash loop gives up here in well under a second,
  and a few give-ups inside five seconds would take down the API again,
  just more slowly. So giving up stops the feed for the rest of the
  instance's life and nothing else: REST, RPC, NOTIFY `channel=` events and
  the admin listener keep serving. The give-up itself is made explicit by
  `Bier.Wal.Watcher` — logged at error level, `[:bier, :wal, :feed,
  :stopped]` telemetry, live table subscribers closed with `bier:closed`
  `feed_stopped`, new ones refused with `503 BIER004`. Restarting the
  instance (or its host application) brings the feed back once the cause
  is fixed.
  """
  def child_spec(%Bier.Config{} = conf) do
    %{
      id: {conf.name, __MODULE__},
      start: {__MODULE__, :start_link, [conf]},
      type: :supervisor,
      restart: :temporary
    }
  end

  @impl Supervisor
  def init(%Bier.Config{} = conf) do
    # Raises (failing the instance's boot) with the exact remediation for a
    # feed that cannot stream. Here rather than in a child, so it runs once
    # per start of this supervisor and never again on a restart inside it.
    :ok = Bier.Wal.validate!(Registry.via(conf.name, Postgrex), conf)

    Supervisor.init([{Bier.Wal.Buffer, conf}, {Bier.Wal.Consumer, conf}],
      strategy: :rest_for_one,
      max_restarts: @max_restarts,
      max_seconds: @max_seconds
    )
  end
end
