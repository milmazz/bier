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

  @doc "Ask every table subscriber to re-run its authorization (Task 10)."
  @spec notify_recheck(term()) :: :ok
  def notify_recheck(name) do
    for pid <- Bier.Events.Registry.table_subscribers(name), do: send(pid, {:bier_wal_recheck})
    :ok
  end
end
