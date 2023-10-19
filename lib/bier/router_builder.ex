defmodule Bier.RouterBuilder do
  @moduledoc """
  Module that builds a router on-the-fly based on the result from the DB introspection

  This module builds a router using `Plug.Router`, the idea is to dispatch JSON
  responses based on the path and method of the incoming requests.

  Each one of the routes are built on-the-fly based on the result from the DB
  introspection process.
  """

  @doc """
  Builds a Router module using `Plug.Router`
  """
  @spec build(Bier.Config.t(), db_structure :: [%{binary() => binary()}]) ::
          {:module, atom(), binary(), any()}
  def build(%Bier.Config{} = conf, db_structure) do
    module_name = Module.concat(conf.name, Router)

    content =
      quote location: :keep,
            bind_quoted: [db_structure: Macro.escape(db_structure), module_name: conf.name] do
        use Plug.Router

        # alias Bier.Plugs.ActionController
        alias Bier.Plugs.FallbackController

        require Logger

        plug(:match)

        plug(Plug.Parsers,
          parsers: [:json],
          pass: ["application/json"],
          json_decoder: Bier.json_library()
        )

        # plug(Bier.Plugs.AuthenticateUser, name: module_name)

        plug(:dispatch)

        # for %{"Name" => table_name, "Schema" => schema, "Type" => _type} <- db_structure do
        #  assigns = %{module_name: module_name, schema: schema, table_name: table_name}

        #  get("/#{table_name}", assigns: assigns, to: ActionController, init_opts: :index)
        #  post("/#{table_name}", assigns: assigns, to: ActionController, init_opts: :post)
        #  delete("/#{table_name}", assigns: assigns, to: ActionController, init_opts: :delete)
        # end

        match(_, to: FallbackController, init_opts: :not_found)
      end

    Module.create(module_name, content, Macro.Env.location(__ENV__))
  end
end
