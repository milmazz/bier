defmodule Bier.Events.Registry do
  @moduledoc """
  Node-shared pub/sub registry for the realtime events endpoint.

  A duplicate-keys `Registry` (mirroring `Bier.Registry`'s role as shared
  infrastructure) whose entries are keyed `{instance_name, channel}`. SSE
  subscriber processes register themselves; `Bier.Events.Listener` broadcasts
  each NOTIFY to the matching entries. Entries die with their process, so
  there is no unsubscribe bookkeeping.
  """

  @doc false
  def child_spec(_opts) do
    Registry.child_spec(keys: :duplicate, name: __MODULE__)
  end

  @doc "Subscribe the calling process to `channel` on `instance`."
  @spec register(term(), String.t()) :: :ok
  def register(instance, channel) do
    {:ok, _owner} = Registry.register(__MODULE__, {instance, channel}, nil)
    :ok
  end

  @doc """
  Send `{:bier_event, channel, payload}` to every subscriber of
  `{instance, channel}`; returns the number of subscribers reached.
  """
  @spec broadcast(term(), String.t(), String.t()) :: non_neg_integer()
  def broadcast(instance, channel, payload) do
    entries = Registry.lookup(__MODULE__, {instance, channel})
    for {pid, _value} <- entries, do: send(pid, {:bier_event, channel, payload})
    length(entries)
  end

  @doc "Number of live subscribers for `{instance, channel}`."
  @spec subscriber_count(term(), String.t()) :: non_neg_integer()
  def subscriber_count(instance, channel) do
    length(Registry.lookup(__MODULE__, {instance, channel}))
  end

  @doc """
  Subscribe the calling process to a table's WAL change feed.

  The entry's value is the role the subscription was authorized against, so
  `Bier.Wal.notify_recheck/1` can re-authorize every live subscriber from
  ONE place — grouping by role and asking the database once per role —
  instead of waking each subscriber to run its own query.
  """
  @spec register_table(term(), {String.t(), String.t()}, String.t() | nil) :: :ok
  def register_table(instance, table_key, role) do
    {:ok, _owner} = Registry.register(__MODULE__, {instance, {:table, table_key}}, role)
    :ok
  end

  @doc "Send `message` to every WAL subscriber of `table_key` on `instance`."
  @spec broadcast_table(term(), {String.t(), String.t()}, term()) :: non_neg_integer()
  def broadcast_table(instance, table_key, message) do
    entries = Registry.lookup(__MODULE__, {instance, {:table, table_key}})
    for {pid, _value} <- entries, do: send(pid, message)
    length(entries)
  end

  @doc """
  Every live WAL table subscriber on `instance`, across all tables.

  Deduplicated: a process registered on several tables (e.g. it wants the
  reset/recheck broadcasts regardless of which table triggered them) would
  otherwise appear once per table it is registered on.
  """
  @spec table_subscribers(term()) :: [pid()]
  def table_subscribers(instance) do
    Registry.select(__MODULE__, [
      {{{instance, {:table, :_}}, :"$1", :_}, [], [:"$1"]}
    ])
    |> Enum.uniq()
  end

  @doc """
  Every live WAL table subscription on `instance` as `{pid, table_key,
  role}` — one entry per subscribed table, so a process watching three
  tables appears three times (unlike `table_subscribers/1`, which
  deduplicates).

  This is the input `Bier.Wal.notify_recheck/1` groups by role.
  """
  @spec table_subscriptions(term()) :: [{pid(), {String.t(), String.t()}, String.t() | nil}]
  def table_subscriptions(instance) do
    Registry.select(__MODULE__, [
      {{{instance, {:table, :"$1"}}, :"$2", :"$3"}, [], [{{:"$2", :"$1", :"$3"}}]}
    ])
  end
end
