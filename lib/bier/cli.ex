defmodule Bier.CLI do
  @moduledoc """
  Command-line interface for running Bier as a standalone, drop-in
  PostgREST-compatible service.

  `run/2` is the core: it takes argv plus an explicit environment and returns
  `%{stdout, stderr, exit}` for terminal commands, or `{:boot, resolved}` for
  the default run-the-server action. It never writes to stdio and never halts —
  the conformance suite drives it directly. (`--ready` is the one command that
  performs IO of its own: it is a health-check *client*, so the outbound probe
  is part of the command, not of the wrapper.) `main/1` is the escript wrapper
  that supplies real stdio and `System.halt/1`.
  """

  alias Bier.CLI.Config
  alias Bier.CLI.ConfigFile
  alias Bier.CLI.DbSettings
  alias Bier.CLI.Ready

  @type result :: %{stdout: iodata(), stderr: iodata(), exit: non_neg_integer()}

  @version Mix.Project.config()[:version]

  @doc ~S"""
  Run the CLI core. `opts[:env]` is a `%{"PGRST_*" => string}` map (defaults to
  an empty map). Returns a `%{stdout, stderr, exit}` map for terminal commands
  (`--ready` included — its probe runs here, via `Bier.CLI.Ready.check/1`), or
  `{:boot, resolved}` for the default run-the-server action.
  """
  @spec run([String.t()], keyword()) :: result() | {:boot, map()}
  def run(argv, opts \\ []) do
    env = Keyword.get(opts, :env, %{})

    # version/help/example print unconditionally — PostgREST answers them from
    # the option parser before any config is read, so a broken PGRST_* var or a
    # missing config file must not mask them.
    case parse_argv(argv) do
      {:version, _file_path} -> ok(version_line())
      {:help, _file_path} -> ok(usage())
      {:example, _file_path} -> ok(example_config())
      {command, file_path} -> load_and_dispatch(command, file_path, env)
    end
  end

  defp load_and_dispatch(command, file_path, env) do
    with {:ok, file} <- read_file(file_path),
         {:ok, resolved} <- Config.load(env, file, %{}),
         {:ok, resolved} <- apply_db_settings(command, resolved, env, file) do
      dispatch(command, resolved)
    else
      {:error, message} -> error(message)
    end
  end

  # PostgREST reads the in-database config (ALTER ROLE ... SET pgrst.*) before
  # dumping the config or running the server (CLI.hs: `when configDbConfig $
  # AppState.readInDbConfig`); the client-only --ready never connects. The
  # re-load slots the role settings above env/file (Config.load/4 `db`).
  defp apply_db_settings(command, resolved, env, file) when command in [:dump_config, :run] do
    with true <- resolved["db-config"],
         {:ok, db} <- DbSettings.fetch(resolved, env) do
      Config.load(env, file, %{}, db)
    else
      false -> {:ok, resolved}
      {:error, _} = err -> err
    end
  end

  defp apply_db_settings(_command, resolved, _env, _file), do: {:ok, resolved}

  defp dispatch(:dump_config, resolved), do: ok(Config.dump(resolved))
  defp dispatch(:run, resolved), do: {:boot, resolved}

  # PostgREST Network.hs isSpecialHostName: bind-only aliases that cannot be
  # dialed by a client.
  @special_hostnames ~w(* *4 !4 *6 !6)

  # The config half of --ready (PostgREST Client.hs `ready` / `getURL`). Bier
  # has no separate admin-server-host key, so the admin host is server-host —
  # exactly upstream's default (admin-server-host aliases to server-host).
  defp dispatch(:ready, resolved) do
    host = resolved["server-host"]

    cond do
      resolved["admin-server-port"] == :unset ->
        error("ERROR: Admin server is not running. Please check admin-server-port config.")

      host in @special_hostnames ->
        error(
          "ERROR: The `--ready` flag cannot be used when server-host is configured as " <>
            "\"#{host}\". Please update your server-host config to \"localhost\"."
        )

      true ->
        ready_url(host, resolved["admin-server-port"])
    end
  end

  # http-client rejects an unparseable URL (a negative admin-server-port, say)
  # with InvalidUrlException *before* opening a socket, so the failure is
  # decided here rather than in the probe — a distinct error flavor from the
  # connection-refused message every transport failure collapses into.
  defp ready_url(host, port) do
    url = "http://#{wrap_ipv6(host)}:#{port}/ready"

    case Ready.validate_url(url) do
      :ok -> Ready.check(url)
      {:error, message} -> error(message)
    end
  end

  # IPv6 literals need brackets in a URL (":" is the port separator).
  defp wrap_ipv6(host) do
    if String.contains?(host, ":"), do: "[#{host}]", else: host
  end

  # The optional positional config-file path is any argv element not starting
  # with "-". The first recognized flag selects the command; the default is
  # :run. Unknown flags are currently ignored (the server boots), and when two
  # commands are passed the first wins — PostgREST instead errors on unknown /
  # conflicting flags. Tightening this belongs with the deferred --example
  # work (issue #45), not this conformance slice.
  defp parse_argv(argv) do
    file_path = Enum.find(argv, fn arg -> not String.starts_with?(arg, "-") end)
    command = Enum.find_value(argv, :run, &flag_command/1)
    {command, file_path}
  end

  defp flag_command("--dump-config"), do: :dump_config
  defp flag_command("--ready"), do: :ready
  defp flag_command("--example"), do: :example
  defp flag_command("-e"), do: :example
  defp flag_command("--version"), do: :version
  defp flag_command("-v"), do: :version
  defp flag_command("--help"), do: :help
  defp flag_command("-h"), do: :help
  defp flag_command(_), do: nil

  defp read_file(nil), do: {:ok, nil}
  defp read_file(path), do: ConfigFile.read(path)

  defp version_line, do: "bier #{@version}\n"

  defp usage do
    """
    Usage: bier [CONFIG_FILE] [OPTIONS]

    Runs Bier as a standalone PostgREST-compatible REST server. Config is read
    from PGRST_* environment variables, an optional CONFIG_FILE, and flags.

    Options:
      --dump-config   Print the loaded configuration and exit
      --ready         Check health by requesting the admin server's /ready
                      endpoint; exits 0 when ready, 1 otherwise
      -e, --example   Print an example configuration file and exit
      -v, --version   Print the version and exit
      -h, --help      Print this help and exit
    """
  end

  # PostgREST's --example prints a config-file template (Config.hs
  # exampleConfigFile). Bier generates its template from the spec table via the
  # default-resolved dump, so the example always shows every implemented key at
  # its default and stays loadable as-is.
  defp example_config do
    {:ok, defaults} = Config.load(%{}, nil, %{})

    [
      """
      ## Bier example configuration (PostgREST-compatible)
      ## Every implemented key at its default value. Each key can also be set
      ## through its PGRST_* environment variable (dashes become underscores),
      ## e.g. server-port -> PGRST_SERVER_PORT.

      """
      | Config.dump(defaults)
    ]
  end

  @doc """
  escript entry point. Supplies the real process environment, writes the
  command's output to stdout/stderr, and halts with its exit code. For the
  default run action it boots one standalone Bier instance and blocks.
  """
  @spec main([String.t()]) :: no_return()
  def main(argv) do
    case run(argv, env: System.get_env()) do
      {:boot, resolved} ->
        boot(resolved)

      %{stdout: out, stderr: err, exit: code} ->
        emit(out, err, code)
    end
  end

  defp emit(out, err, code) do
    IO.write(out)
    IO.write(:stderr, err)
    System.halt(code)
  end

  # Bier's boot schema is stricter than the parse layer (which --dump-config
  # pins), so the resolved config is validated here, at boot — a rejected value
  # is fatal with the message on stderr, like the jwt-secret/admin-port fatals.
  defp boot(resolved) do
    case Config.validated_start_opts(resolved) do
      {:ok, opts} ->
        {:ok, _} = Application.ensure_all_started(:bier)
        {:ok, _pid} = Bier.start_link(opts)
        Process.sleep(:infinity)

      {:error, message} ->
        emit("", [message, "\n"], 1)
    end
  end

  defp ok(stdout), do: %{stdout: stdout, stderr: "", exit: 0}
  defp error(message), do: %{stdout: "", stderr: [message, "\n"], exit: 1}
end
