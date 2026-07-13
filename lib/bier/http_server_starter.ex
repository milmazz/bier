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
          [scheme: conf.router[:scheme], plug: plug, http_options: [compress: false]] ++
            listen_opts(conf)
        }
      )

    chmod_unix_socket(conf)

    {:noreply, state}
  end

  # server-unix-socket replaces the TCP listener with a Unix domain socket
  # (Bandit requires port 0 for :local addresses). A stale socket file from a
  # previous run would fail the bind, so it is removed first — PostgREST does
  # the same. Otherwise bind the configured server-host address.
  defp listen_opts(%Bier.Config{server_unix_socket: path}) when is_binary(path) do
    _ = File.rm(path)
    [ip: {:local, path}, port: 0]
  end

  defp listen_opts(%Bier.Config{} = conf) do
    [ip: Bier.Config.host_address(conf.server_host), port: conf.router[:port]]
  end

  # Apply server-unix-socket-mode to the freshly bound socket file. The mode
  # string was validated at boot (Bier.Config), so parse failure here is
  # impossible; File.chmod! keeps any OS-level failure loud.
  defp chmod_unix_socket(%Bier.Config{server_unix_socket: path} = conf) when is_binary(path) do
    {:ok, mode} = Bier.Config.parse_socket_mode(conf.server_unix_socket_mode)
    File.chmod!(path, mode)
  end

  defp chmod_unix_socket(_conf), do: :ok
end
