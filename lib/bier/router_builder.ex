defmodule Bier.RouterBuilder do
  @moduledoc """
  Builds the per-instance router module.

  Unlike the legacy per-table approach, the router is now a thin catch-all: it
  forwards *every* request to `Bier.Plugs.ActionController`, which resolves the
  target `{schema, relation}` at request time from the path plus the
  `Accept-Profile`/`Content-Profile` headers. This is required to express
  PostgREST's schema selection (and `/rpc/*`) which a static route table cannot.

  The generated module is named `<instance_name>.Router` and rebuilt on every
  boot, so it is not checked in.
  """

  @doc """
  Builds a `Plug.Router` module that dispatches everything to
  `Bier.Plugs.ActionController`, threading the instance name through `assigns`.
  """
  @spec build(Bier.Config.t(), term()) :: {:module, atom(), binary(), any()}
  def build(%Bier.Config{} = conf, _db_structure) do
    supervisor_name = conf.name

    content =
      quote location: :keep do
        use Plug.Router

        alias Bier.Plugs.ActionController

        plug(:match)

        plug(Bier.Plugs.ReadBody)

        plug(:dispatch)

        match _ do
          var!(conn)
          |> Plug.Conn.assign(:supervisor_name, unquote(supervisor_name))
          |> ActionController.call(ActionController.init([]))
        end
      end

    conf.name
    |> Module.concat(Router)
    |> Module.create(content, Macro.Env.location(__ENV__))
  end
end
