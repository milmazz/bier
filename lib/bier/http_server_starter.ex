defmodule Bier.HttpServerStarter do
  @moduledoc """
  Sets up the initial router based on the DB introspection process
  """
  use GenServer

  def start_link(%Bier.Config{name: name} = conf) do
    GenServer.start_link(__MODULE__, conf, name: Bier.Registry.via(name, __MODULE__))
  end

  @impl GenServer
  def init(%Bier.Config{name: name, db_schemas: schemas} = conf) do
    conn = Bier.Registry.via(name, Postgrex)

    # The request pipeline resolves {schema, relation} on every request, so
    # the introspection snapshot lives in persistent_term (read-mostly),
    # keyed by the instance name — see Bier.SchemaCache. The catch-all router
    # forwards everything to ActionController.
    cache = Bier.SchemaCache.load!(name, conn, schemas)
    Bier.SchemaCache.put(name, cache)

    {:module, plug, _binary, _} = Bier.RouterBuilder.build(conf, cache.relations)

    {:ok, %{conf: conf, plug: plug}, {:continue, :start_webserver}}
  end

  @impl GenServer
  def handle_continue(:start_webserver, %{conf: conf, plug: plug} = state) do
    {:ok, _} =
      DynamicSupervisor.start_child(
        Bier.Registry.via(conf.name, DynamicSupervisor),
        {
          Bandit,
          # PostgREST does not compress responses and always emits a
          # `Content-Length`. Disabling Bandit's content-encoding keeps parity
          # (Bandit otherwise strips Content-Length and adds `Vary:
          # Accept-Encoding`, even when it does not actually compress).
          scheme: conf.router[:scheme],
          plug: plug,
          port: conf.router[:port],
          http_options: [compress: false]
        }
      )

    {:noreply, state}
  end

  # TODO: Check if it's possible to subscribe to all the changes in the
  # database, and capture those events via `Postgrex.Notifications`, that way
  # you can insert here a `handle_info/2` to update the db structure and also
  # re-build? the Router?
end
