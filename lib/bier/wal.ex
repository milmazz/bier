defmodule Bier.Wal do
  @moduledoc """
  WAL change-feed entry points shared across the supervisor, the boot
  validation in `Bier.HttpServerStarter`, and the schema-reload hook.
  """

  @doc """
  Fail-fast boot validation (the `db-schemas` precedent, #96): when
  `events_publication` is configured the server must be able to stream it.
  Raises with the exact remediation statement for whichever precondition is
  missing.
  """
  @spec validate!(pool :: term(), Bier.Config.t()) :: :ok
  def validate!(_pool, %Bier.Config{events_publication: nil}), do: :ok

  def validate!(pool, %Bier.Config{events_publication: publication}) do
    %{rows: [[wal_level]]} = Postgrex.query!(pool, "SHOW wal_level", [])

    wal_level == "logical" ||
      raise ArgumentError,
            "events_publication is configured but wal_level is '#{wal_level}' — " <>
              "run: ALTER SYSTEM SET wal_level = logical; and restart PostgreSQL"

    %{rows: pub_rows} =
      Postgrex.query!(pool, "SELECT 1 FROM pg_publication WHERE pubname = $1", [publication])

    pub_rows != [] ||
      raise ArgumentError,
            "events_publication '#{publication}' does not exist — " <>
              "run: CREATE PUBLICATION \"#{publication}\" FOR TABLE ...;"

    %{rows: [[can_replicate]]} =
      Postgrex.query!(
        pool,
        "SELECT rolreplication OR rolsuper FROM pg_roles WHERE rolname = current_user",
        []
      )

    can_replicate ||
      raise ArgumentError,
            "the connection role lacks the REPLICATION attribute — " <>
              "run: ALTER ROLE <role> REPLICATION;"

    :ok
  end

  # Each subscriber's re-authorization is one round trip on the instance's
  # shared Postgrex pool (`pool_size`, default 10). Waking every subscriber
  # at once would queue hundreds of checkouts in front of ordinary API
  # requests, so subscribers are told how wide a window to scatter
  # themselves across: ~20ms per subscriber, so the rate stays near
  # 50 checks/second whatever the subscriber count.
  #
  # The window scales from (effectively) zero: a handful of subscribers
  # re-check within milliseconds, which matters because the window is also
  # how long a just-revoked column can still reach a live subscriber. The
  # 10s ceiling bounds that lag at scale.
  @recheck_window_per_subscriber 20
  @min_recheck_window 1
  @max_recheck_window 10_000

  @doc "Ask every table subscriber to re-run its authorization (Task 10)."
  @spec notify_recheck(term()) :: :ok
  def notify_recheck(name) do
    subscribers = Bier.Events.Registry.table_subscribers(name)
    window = recheck_window(length(subscribers))

    for pid <- subscribers, do: send(pid, {:bier_wal_recheck, window})
    :ok
  end

  @doc false
  @spec recheck_window(non_neg_integer()) :: pos_integer()
  def recheck_window(subscriber_count) do
    subscriber_count
    |> Kernel.*(@recheck_window_per_subscriber)
    |> max(@min_recheck_window)
    |> min(@max_recheck_window)
  end
end
