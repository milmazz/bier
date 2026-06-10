defmodule Bier.CLI.ConfigFile do
  @moduledoc """
  Parses the PostgREST-compatible config-file subset into a
  `%{kebab_key => raw_value}` map: `key = value` lines, `#` comments, blank
  lines, double-quoted strings (with `\\"` escapes), bare integers, and bare
  `true`/`false`. Raw values are returned untyped; `Bier.CLI.Config` coerces
  them per the target key.
  """

  @doc "Read and parse a config file. A missing file is a fatal error."
  @spec read(Path.t()) :: {:ok, map()} | {:error, String.t()}
  def read(path) do
    case File.read(path) do
      {:ok, contents} ->
        parse(contents)

      {:error, reason} ->
        {:error, "could not read config file #{path}: #{:file.format_error(reason)}"}
    end
  end

  @doc "Parse config-file contents."
  @spec parse(String.t()) :: {:ok, map()} | {:error, String.t()}
  def parse(contents) do
    contents
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.reduce_while({:ok, %{}}, fn line, {:ok, acc} ->
      case parse_line(line) do
        {:ok, {key, value}} -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp parse_line(line) do
    case String.split(line, "=", parts: 2) do
      [raw_key, raw_value] ->
        {:ok, {String.trim(raw_key), parse_value(String.trim(raw_value))}}

      _ ->
        {:error, "malformed config line: #{inspect(line)}"}
    end
  end

  # A double-quoted string: strip the surrounding quotes and unescape \" → ".
  # The guard requires a non-empty suffix that ends with a closing quote, so
  # `""` parses to "" and an unterminated `"foo` falls through to the
  # bare-string clause below.
  defp parse_value(<<?", inner::binary>>)
       when byte_size(inner) >= 1 and
              binary_part(inner, byte_size(inner) - 1, 1) == "\"" do
    inner
    |> binary_part(0, byte_size(inner) - 1)
    |> String.replace(~S(\"), ~S("))
  end

  defp parse_value("true"), do: true
  defp parse_value("false"), do: false

  defp parse_value(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> value
    end
  end
end
