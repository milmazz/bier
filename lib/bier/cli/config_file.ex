defmodule Bier.CLI.ConfigFile do
  @moduledoc """
  Parses the PostgREST-compatible config-file subset into a
  `%{kebab_key => raw_value}` map: `key = value` lines, `#` comments (whole
  lines or trailing a value, as configurator-pg allows), blank lines,
  double-quoted strings (with `\\"` escapes), bare integers, and bare
  `true`/`false`. A `#` inside a quoted string is literal. Raw values are
  returned untyped; `Bier.CLI.Config` coerces them per the target key.
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
    with [raw_key, raw_value] <- String.split(line, "=", parts: 2),
         {:ok, value} <- parse_value(String.trim(raw_value)) do
      {:ok, {String.trim(raw_key), value}}
    else
      [_no_equals] -> {:error, "malformed config line: #{inspect(line)}"}
      {:error, reason} -> {:error, "#{reason}: #{inspect(line)}"}
    end
  end

  # A double-quoted string: everything up to the closing quote, honoring \"
  # escapes. After the closing quote only whitespace or a trailing `# comment`
  # may follow — anything else (including a missing closing quote) is a
  # malformed line, as in PostgREST's configurator, rather than a silently
  # mangled value.
  defp parse_value(<<?", rest::binary>>) do
    with {:ok, inner, trailing} <- take_quoted(rest, []),
         :ok <- comment_or_blank(trailing) do
      {:ok, inner}
    end
  end

  # A bare (unquoted) value ends at the first `#`, which starts an end-of-line
  # comment; PostgREST-style files quote any string value that needs a literal
  # `#`.
  defp parse_value(value) do
    bare = value |> String.split("#", parts: 2) |> hd() |> String.trim()

    case bare do
      "true" ->
        {:ok, true}

      "false" ->
        {:ok, false}

      _ ->
        case Integer.parse(bare) do
          {int, ""} -> {:ok, int}
          _ -> {:ok, bare}
        end
    end
  end

  defp take_quoted(<<?\\, ?", rest::binary>>, acc), do: take_quoted(rest, [?" | acc])

  defp take_quoted(<<?", rest::binary>>, acc),
    do: {:ok, acc |> Enum.reverse() |> List.to_string(), rest}

  defp take_quoted(<<char::utf8, rest::binary>>, acc), do: take_quoted(rest, [char | acc])

  # Not valid UTF-8: keep the raw byte rather than crash on unusual input.
  defp take_quoted(<<byte, rest::binary>>, acc), do: take_quoted(rest, [byte | acc])

  defp take_quoted(<<>>, _acc), do: {:error, "unterminated quoted value"}

  defp comment_or_blank(trailing) do
    case String.trim_leading(trailing) do
      "" -> :ok
      "#" <> _comment -> :ok
      _other -> {:error, "unexpected characters after quoted value"}
    end
  end
end
