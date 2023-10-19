defmodule Bier do
  # TODO: Put something more here, maybe reading the README docs? once you have
  # something there of course
  @moduledoc false

  @schema [
    name: [
      type: :atom,
      required: false,
      default: __MODULE__,
      doc: "Used for the supervisor name registration."
    ],
    router: [
      type: :non_empty_keyword_list,
      required: false,
      subsection: "REST endpoint options",
      # TODO: Change the scheme to HTTPS
      default: [port: 4040, scheme: :http],
      doc: """
      Options needed for the Web endpoint, which under the hood is powered by
      `Bandit`.
      """,
      keys: [
        port: [
          type: :pos_integer,
          required: true,
          default: 4040,
          doc: "The TCP port to bind the web server."
        ],
        scheme: [
          type: {:in, [:http, :https]},
          required: true,
          # TODO: Change this to HTTPS
          default: :http,
          doc: "Either `:https` or `:http`."
        ]
      ]
    ]
  ]
  use Supervisor

  alias Bier.Registry

  @type name :: term()

  @doc """
  Starts a `Bier` supervision tree linked to the current process.

  ## Options

  #{NimbleOptions.docs(@schema)}
  """
  @spec start_link(Keyword.t()) :: Supervisor.on_start()
  def start_link(opts) do
    conf = Bier.Config.new!(opts, @schema)

    Supervisor.start_link(__MODULE__, conf, name: Registry.via(conf.name, nil, conf))
  end

  @spec child_spec(Keyword.t()) :: Supervisor.child_spec()
  def child_spec(opts) do
    opts
    |> super()
    |> Supervisor.child_spec(id: Keyword.get(opts, :name, __MODULE__))
  end

  @impl Supervisor
  def init(%Bier.Config{name: _name} = conf) do
    children = [
      # TODO: Allow the user to configure more things
      # Start Postgrex or Ecto, to run the introspection query in the HttpServerStarter
      {Bier.HttpServerStarter, conf},
      {DynamicSupervisor,
       strategy: :one_for_one, name: Registry.via(conf.name, DynamicSupervisor)}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Returns the configured JSON encoding library for Bier.

  To customize the JSON library, including the following
  in your `config/config.exs`:

      config :bier, :json_library, AlternativeJsonLibrary

  """
  def json_library do
    Application.get_env(:bier, :json_library, Jason)
  end
end
