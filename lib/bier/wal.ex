defmodule Bier.Wal do
  @moduledoc """
  WAL change-feed entry points: the boot validation `Bier.Wal.Supervisor`
  runs, the feed-stopped flag `Bier.Wal.Watcher` sets and `Bier.Events`
  reads, and the re-authorization the schema-reload hook triggers.
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

  def validate!(pool, %Bier.Config{events_publication: publication} = conf) do
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
    warn_if_partition_truncates_unpublished(pool, publication)
    warn_if_replica_identities_differ(pool, publication)

    :ok
  rescue
    # This runs before `HttpServerStarter` loads the schema cache (see
    # `Bier.Wal.Supervisor.init/1`), so with the feed configured it is the
    # first boot step to touch the database. A database that is unreachable
    # at boot must leave the same PGRST002 trace the schema-cache load
    # leaves when it is the first (`Bier.SchemaCache.load!/4`), not just an
    # unlogged connection error. Only connection failures: the remediation
    # `ArgumentError`s above are configuration, already self-explanatory.
    error in DBConnection.ConnectionError ->
      Bier.ErrorLogger.schema_cache_load_error(conf.name, error)
      reraise error, __STACKTRACE__
  catch
    :exit, reason ->
      Bier.ErrorLogger.schema_cache_load_error(conf.name, reason)
      exit(reason)
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

  # The one degradation the feed cannot announce. With
  # `publish_via_partition_root = true`, PostgreSQL reports every change of
  # a partition tree as its published ancestor — except a TRUNCATE that
  # names only partitions (`TRUNCATE orders_2026`): pgoutput skips those
  # outright, so they never reach the slot. Nothing arrives to detect, so
  # no per-event `bier:reset` is possible, and subscribers to the
  # partitioned table keep rows that no longer exist. It cannot be fixed
  # from here either: a publication without the setting does not name the
  # partitioned table at all. So it is named once, at feed start, and only
  # for the configuration it applies to: a via-root publication that
  # actually lists a partitioned table. A warning, not a refusal — the
  # operator may well never truncate a single partition.
  defp warn_if_partition_truncates_unpublished(pool, publication) do
    %{rows: rows} =
      Postgrex.query!(
        pool,
        """
        SELECT format('%I.%I', pt.schemaname, pt.tablename)
        FROM pg_publication p
        JOIN pg_publication_tables pt ON pt.pubname = p.pubname
        JOIN pg_class c
          ON c.relname = pt.tablename
         AND c.relnamespace = to_regnamespace(quote_ident(pt.schemaname))
        WHERE p.pubname = $1 AND p.pubviaroot AND c.relkind = 'p'
        ORDER BY 1
        """,
        [publication]
      )

    if rows != [] do
      require Logger

      Logger.warning(
        "Bier's WAL change feed: publication '#{publication}' publishes the partitioned " <>
          "table(s) #{rows |> List.flatten() |> Enum.join(", ")} via the partition root. " <>
          "PostgreSQL does not publish a TRUNCATE of a single partition in that mode, so " <>
          "subscribers to those tables are never told about one (no event, no bier:reset). " <>
          "Truncate the partitioned table itself, or DELETE from the partition, when " <>
          "subscribers must see it."
      )
    end

    :ok
  end

  # The other silent degradation of a via-root publication: wrong `old`
  # data. Each partition LOGS its old tuple by its own REPLICA IDENTITY, but
  # pgoutput LABELS it (`O` full / `K` key) from the relation it reports the
  # change as — the root — and `Bier.Wal.Pgoutput` shapes a `K` image to the
  # root's identity columns. A DEFAULT partition under a FULL root therefore
  # reports every never-logged column as `null` in a `"full"` `old`; a FULL
  # partition under a DEFAULT root loses the columns it did log. Nothing in
  # the stream says which happened, so the mismatch is named at boot.
  #
  # Only leaves are compared: an intermediate partitioned table stores no
  # rows and logs nothing. Any difference counts, including NOTHING, and a
  # USING INDEX matches only when the leaf's identity index is a partition
  # (at any depth) of the root's own identity index.
  defp warn_if_replica_identities_differ(pool, publication) do
    %{rows: rows} =
      Postgrex.query!(
        pool,
        """
        WITH roots AS (
          SELECT r.oid, format('%I.%I', pt.schemaname, pt.tablename) AS name,
                 r.relreplident AS ident,
                 (SELECT i.indexrelid FROM pg_index i
                  WHERE i.indrelid = r.oid AND i.indisreplident) AS ident_index
          FROM pg_publication p
          JOIN pg_publication_tables pt ON pt.pubname = p.pubname
          JOIN pg_class r
            ON r.relname = pt.tablename
           AND r.relnamespace = to_regnamespace(quote_ident(pt.schemaname))
          WHERE p.pubname = $1 AND p.pubviaroot AND r.relkind = 'p'
        ),
        leaves AS (
          SELECT roots.name AS root, roots.ident AS root_ident,
                 roots.ident_index AS root_index,
                 format('%I.%I', n.nspname, l.relname) AS name,
                 l.relreplident AS ident,
                 (SELECT i.indexrelid FROM pg_index i
                  WHERE i.indrelid = l.oid AND i.indisreplident) AS ident_index
          FROM roots
          CROSS JOIN LATERAL pg_partition_tree(roots.oid) t
          JOIN pg_class l ON l.oid = t.relid
          JOIN pg_namespace n ON n.oid = l.relnamespace
          WHERE t.isleaf
        )
        SELECT root, root_ident::text, root_index::regclass::text,
               array_agg(name || '|' || ident::text || '|' || COALESCE(ident_index::regclass::text, '')
                         ORDER BY name)
        FROM leaves
        WHERE ident <> root_ident
           OR (ident = 'i' AND NOT EXISTS (
                 SELECT 1 FROM pg_partition_ancestors(ident_index) a
                 WHERE a.relid = root_index))
        GROUP BY root, root_ident, root_index
        ORDER BY root
        """,
        [publication]
      )

    if rows != [] do
      require Logger

      trees =
        Enum.map_join(rows, "; ", fn [root, ident, index, leaves] ->
          named =
            Enum.map_join(leaves, ", ", fn leaf ->
              [name, leaf_ident, leaf_index] = String.split(leaf, "|", parts: 3)
              "#{name} (#{identity_name(leaf_ident, leaf_index)})"
            end)

          "#{root} (#{identity_name(ident, index)}) -> #{named}"
        end)

      Logger.warning(
        "Bier's WAL change feed: publication '#{publication}' publishes partitioned " <>
          "tables via the partition root, and their partitions' REPLICA IDENTITY differs " <>
          "from the root's: #{trees}. Each partition logs its old row by its own identity, " <>
          "but `old` and `old_kind` are labelled and shaped from the root's, so `old` is " <>
          "wrong for these partitions — e.g. a DEFAULT partition under a FULL root reports " <>
          "never-logged columns as null on a key-changing UPDATE or a DELETE, and a FULL " <>
          "partition under a DEFAULT root loses the columns it logged. Set the same " <>
          "REPLICA IDENTITY on the partitioned table and every partition."
      )
    end

    :ok
  end

  defp identity_name("d", _index), do: "DEFAULT"
  defp identity_name("f", _index), do: "FULL"
  defp identity_name("n", _index), do: "NOTHING"
  defp identity_name("i", index), do: "USING INDEX #{index}"

  @doc """
  True once this instance's WAL feed has been given up on
  (`Bier.Wal.Watcher`): `Bier.Wal.Supervisor` exhausted its restart budget
  and the feed stays stopped until the instance is restarted. Read on every
  table subscription, so it lives in `:persistent_term` (lock-free reads;
  the write happens at most once per instance lifetime).
  """
  @spec feed_stopped?(term()) :: boolean()
  def feed_stopped?(name), do: :persistent_term.get(feed_key(name), false)

  @doc false
  @spec mark_feed_stopped(term()) :: :ok
  def mark_feed_stopped(name), do: :persistent_term.put(feed_key(name), true)

  @doc false
  @spec mark_feed_running(term()) :: :ok
  def mark_feed_running(name) do
    # Only erase a flag that is actually there: erasing a persistent_term
    # key triggers a global scan, and the common case (no prior give-up
    # under this name) has nothing to erase.
    if feed_stopped?(name), do: :persistent_term.erase(feed_key(name))
    :ok
  end

  defp feed_key(name), do: {__MODULE__, :feed_stopped, name}

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
    # Only a CONFIRMED privilege loss revokes. The role itself having been
    # dropped is one: `has_column_privilege`/`pg_has_role` then raise
    # `42704 undefined_object`, which is real evidence every subscription of
    # that role is no longer valid. Anything else — a statement timeout, a
    # cancelled query, a failover, pool contention
    # (`DBConnection.ConnectionError`) — says nothing about the role's
    # privileges, and revoking on it would cut every subscriber of that role
    # loose over a transient fault. Those subscribers keep the columns they
    # have and the next reload gets another chance to actually verify.
    error in Postgrex.Error ->
      case error do
        %Postgrex.Error{postgres: %{code: :undefined_object}} -> notify_all(entries, :revoked)
        _other -> notify_all(entries, :keep)
      end

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
