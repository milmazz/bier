defmodule Bier.HttpServerStarter do
  @moduledoc """
  Sets up the initial router based on the DB introspection process
  """
  use GenServer

  def start_link(%Bier.Config{name: name} = conf) do
    GenServer.start_link(__MODULE__, conf, name: Bier.Registry.via(name, __MODULE__))
  end

  @impl GenServer
  def init(conf) do
    # TODO: DB introspection
    db_structure = [
      %{"Name" => "todos", "Schema" => "api", "Type" => "something"}
    ]

    {:module, plug, _binary, _} = Bier.RouterBuilder.build(conf, db_structure)
    {:ok, %{conf: conf, db_structure: db_structure, plug: plug}, {:continue, :start_webserver}}
  end

  @impl GenServer
  def handle_continue(:start_webserver, %{conf: conf, plug: plug} = state) do
    {:ok, _} =
      DynamicSupervisor.start_child(
        Bier.Registry.via(conf.name, DynamicSupervisor),
        {
          Bandit,
          scheme: conf.router[:scheme], plug: plug, port: conf.router[:port]
        }
      )

    {:noreply, state}
  end

  # TODO: Check if it's possible to subscribe to all the changes in the
  # database, and capture those events via `Postgrex.Notifications`, that way
  # you can insert here a `handle_info/2` to update the db structure and also
  # re-build? the Router?
end
