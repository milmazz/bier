defmodule Bier.CliCase do
  @moduledoc """
  Drives a `kind: cli` conformance case through `Bier.CLI.run/2` in-process and
  returns a normalized `%{stdout, stderr, exit}` map (iodata flattened to
  strings). Any `config.file` map is written to a temp file; `config.env`
  becomes the env map passed to the core.
  """

  @doc "Run a CLI conformance case and return its normalized result."
  def perform(%Bier.ConformanceCase{request: req, config: config}) do
    env = Map.get(config, "env", %{})
    file_path = write_config_file(Map.get(config, "file"))
    argv = build_argv(Map.get(req, "flag"), file_path)

    try do
      result = Bier.CLI.run(argv, env: env)

      %{
        stdout: IO.iodata_to_binary(result.stdout),
        stderr: IO.iodata_to_binary(result.stderr),
        exit: result.exit
      }
    after
      if file_path, do: File.rm(file_path)
    end
  end

  # The case `flag` is either a CLI flag ("--dump-config") or a config-file path
  # that does not exist ("does_not_exist.conf", case 1719).
  defp build_argv(nil, file_path), do: List.wrap(file_path)
  defp build_argv("--" <> _ = flag, file_path), do: List.wrap(file_path) ++ [flag]
  defp build_argv(path, _file_path), do: [path]

  defp write_config_file(nil), do: nil

  defp write_config_file(file_map) do
    path = Path.join(System.tmp_dir!(), "bier_conf_#{System.unique_integer([:positive])}.conf")
    File.write!(path, render_file(file_map))
    path
  end

  defp render_file(file_map) do
    Enum.map_join(file_map, "\n", fn {k, v} -> "#{k} = #{render_value(v)}" end) <> "\n"
  end

  defp render_value(v) when is_binary(v), do: ~s("#{String.replace(v, ~S("), ~S(\"))}")
  defp render_value(v) when is_boolean(v), do: to_string(v)
  defp render_value(v) when is_integer(v), do: Integer.to_string(v)
end
