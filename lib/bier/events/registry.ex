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

  @doc "Subscribe the calling process to a table's WAL change feed."
  @spec register_table(term(), {String.t(), String.t()}) :: :ok
  def register_table(instance, table_key) do
    {:ok, _owner} = Registry.register(__MODULE__, {instance, {:table, table_key}}, nil)
    :ok
  end

  @doc "Send `message` to every WAL subscriber of `table_key` on `instance`."
  @spec broadcast_table(term(), {String.t(), String.t()}, term()) :: non_neg_integer()
  def broadcast_table(instance, table_key, message) do
    entries = Registry.lookup(__MODULE__, {instance, {:table, table_key}})
    for {pid, _value} <- entries, do: send(pid, message)
    length(entries)
  end

  @doc "Every live WAL table subscriber on `instance`, across all tables."
  @spec table_subscribers(term()) :: [pid()]
  def table_subscribers(instance) do
    Registry.select(__MODULE__, [
      {{{instance, {:table, :_}}, :"$1", :_}, [], [:"$1"]}
    ])
  end
end
