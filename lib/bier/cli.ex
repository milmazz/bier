defmodule Bier.CLI do
  @moduledoc """
  Command-line interface for running Bier as a standalone, drop-in
  PostgREST-compatible service.

  `run/2` is the pure core: it takes argv plus an explicit environment and
  returns `%{stdout, stderr, exit}` for terminal commands, or `{:boot,
  resolved}` for the default run-the-server action. It performs no IO and never
  halts — the conformance suite drives it directly. `main/1` (added separately)
  is the escript wrapper that supplies real IO and `System.halt/1`.
  """

  alias Bier.CLI.Config
  alias Bier.CLI.ConfigFile

  @type result :: %{stdout: iodata(), stderr: iodata(), exit: non_neg_integer()}

  @version Mix.Project.config()[:version]

  @doc ~S"""
  Run the CLI core. `opts[:env]` is a `%{"PGRST_*" => string}` map (defaults to
  an empty map). Returns a `%{stdout, stderr, exit}` map for terminal commands,
  or `{:boot, resolved}` for the default run-the-server action.
  """
  @spec run([String.t()], keyword()) :: result() | {:boot, map()}
  def run(argv, opts \\ []) do
    env = Keyword.get(opts, :env, %{})

    # version/help print unconditionally — PostgREST answers them from the
    # option parser before any config is read, so a broken PGRST_* var or a
    # missing config file must not mask them.
    case parse_argv(argv) do
      {:version, _file_path} -> ok(version_line())
      {:help, _file_path} -> ok(usage())
      {command, file_path} -> load_and_dispatch(command, file_path, env)
    end
  end

  defp load_and_dispatch(command, file_path, env) do
    with {:ok, file} <- read_file(file_path),
         {:ok, resolved} <- Config.load(env, file, %{}) do
      dispatch(command, resolved)
    else
      {:error, message} -> error(message)
    end
  end

  defp dispatch(:dump_config, resolved), do: ok(Config.dump(resolved))
  defp dispatch(:run, resolved), do: {:boot, resolved}

  # The optional positional config-file path is any argv element not starting
  # with "-". The first recognized flag selects the command; the default is
  # :run. Unknown flags are currently ignored (the server boots), and when two
  # commands are passed the first wins — PostgREST instead errors on unknown /
  # conflicting flags. Tightening this belongs with the deferred --ready /
  # --example work (issue #45), not this conformance slice.
  defp parse_argv(argv) do
    file_path = Enum.find(argv, fn arg -> not String.starts_with?(arg, "-") end)
    command = Enum.find_value(argv, :run, &flag_command/1)
    {command, file_path}
  end

  defp flag_command("--dump-config"), do: :dump_config
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
      -v, --version   Print the version and exit
      -h, --help      Print this help and exit
    """
  end

  @doc """
  escript entry point. Supplies the real process environment, writes the
  command's output to stdout/stderr, and halts with its exit code. For the
  default run action it boots one standalone Bier instance and blocks.
  """
  @spec main([String.t()]) :: no_return()
  def main(argv) do
    case run(argv, env: System.get_env()) do
      {:boot, resolved} -> boot(resolved)
      %{stdout: out, stderr: err, exit: code} -> emit(out, err, code)
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
