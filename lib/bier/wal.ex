defmodule Bier.Wal do
  @moduledoc """
  WAL change-feed entry points shared across the supervisor, the boot
  validation in `Bier.HttpServerStarter`, and the schema-reload hook.
  """

  alias Bier.Wal.Authorize

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

    warn_if_slots_tight(pool)

    :ok
  end

  # Deliberately a warning, not a `raise`. The three checks above are
  # configuration: they cannot come right on their own, so failing boot is
  # the useful response. Slot exhaustion is transient — another instance or
  # a subscription elsewhere releases one — and `Bier.Wal.Consumer` retries
  # slot creation on a bounded backoff, so failing boot here would turn a
  # condition that heals itself into an API outage. Naming it at boot still
  # saves the operator from diagnosing a `53400` in the logs later.
  defp warn_if_slots_tight(pool) do
    %{rows: [[used, limit]]} =
      Postgrex.query!(
        pool,
        "SELECT (SELECT count(*) FROM pg_replication_slots), " <>
          "current_setting('max_replication_slots')::int",
        []
      )

    if used >= limit do
      require Logger

      Logger.warning(
        "Bier's WAL change feed needs a replication slot but all #{limit} are in use " <>
          "(max_replication_slots). The consumer will retry on a backoff; to raise the " <>
          "ceiling run: ALTER SYSTEM SET max_replication_slots = <n>; and restart PostgreSQL"
      )
    end

    :ok
  end

  @doc """
  Re-authorize every live table subscriber, pushing each one its verdict.

  Runs the check HERE rather than waking each subscriber to run its own.
  A reload can wake hundreds of subscribers at once, and per-subscriber
  queries would queue that many checkouts against the instance's shared
  pool (`pool_size`, default 10), starving ordinary API requests — while
  scattering them across a window would instead leave a just-revoked
  column reaching live subscribers for the length of that window. Grouping
  by role and asking once per DISTINCT role (typically one) is both
  immediate and bounded: the work scales with the number of roles, not the
  number of subscribers.

  Each subscriber is sent `{:bier_wal_recheck, verdict}`, where verdict is
  `{:ok, columns}` (possibly narrowed), `:revoked`, or `:keep`.
  """
  @spec notify_recheck(term()) :: :ok
  def notify_recheck(name) do
    case Bier.Events.Registry.table_subscriptions(name) do
      [] -> :ok
      subscriptions -> recheck(name, subscriptions)
    end
  end

  defp recheck(name, subscriptions) do
    config = Bier.Registry.config(name)
    pool = Bier.Registry.via(name, Postgrex)

    subscriptions
    |> Enum.group_by(fn {_pid, _table, role} -> role end)
    |> Enum.each(fn {role, entries} -> recheck_role(pool, config, role, entries) end)

    :ok
  end

  defp recheck_role(pool, config, role, entries) do
    tables = entries |> Enum.map(fn {_pid, table, _role} -> table end) |> Enum.uniq()
    authorized = Authorize.columns(pool, role, config.events_publication, tables)

    entries
    |> Enum.group_by(fn {pid, _table, _role} -> pid end)
    |> Enum.each(fn {pid, pid_entries} ->
      pid_tables = Enum.map(pid_entries, fn {_pid, table, _role} -> table end)
      send(pid, {:bier_wal_recheck, verdict(authorized, pid_tables)})
    end)
  rescue
    # These two are NOT equivalent and deliberately get different outcomes.
    # A `Postgrex.Error` (the role itself was dropped, say — then
    # `has_column_privilege` raises `undefined_object`) is real evidence the
    # subscription is no longer valid. A `DBConnection.ConnectionError` is
    # pool contention or an infrastructure hiccup and says nothing about the
    # role's privileges, so those subscribers keep the columns they have and
    # the next reload gets another chance to actually verify.
    _error in Postgrex.Error ->
      notify_all(entries, :revoked)

    _error in DBConnection.ConnectionError ->
      notify_all(entries, :keep)
  end

  defp notify_all(entries, verdict) do
    for {pid, _table, _role} <- entries, do: send(pid, {:bier_wal_recheck, verdict})
    :ok
  end

  # A subscription survives only if EVERY table it holds still passes. The
  # surviving column map is the FRESH one, so a grant that merely narrowed
  # takes effect rather than the subscriber keeping the column it just lost.
  defp verdict(authorized, pid_tables) do
    if Enum.all?(pid_tables, &is_map_key(authorized, &1)) do
      {:ok, Map.take(authorized, pid_tables)}
    else
      :revoked
    end
  end
end
