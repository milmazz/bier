defmodule Bier.JWT.RoleClaim do
  @moduledoc """
  The `jwt-role-claim-key` JSPath: where in the JWT claims the database role
  lives (default `.role`).

  Mirrors PostgREST v14.12's `PostgREST.Config.JSPath` exactly:

    * grammar — one or more expressions, each a key (`.bare` where bare is
      letters/digits/`_$@`, or `."quoted"` admitting anything but `"`), an
      array index (`[0]`), or a filter (`[?(@ == "text")]` with `==`, `!=`,
      `^==`, `==^`, `*==`), which may only close the path;
    * the parse-failure message (`failed to parse role-claim-key value (…)`),
      pinned by conformance case 1711;
    * the `--dump-config` canonical form (`dumpJSPath`): keys always quoted
      (`."role"`), single-spaced filters. Haskell `show`'s escaping of control
      and non-ASCII characters is not reproduced — upstream itself carries a
      TODO admitting its key quoting is imperfect for special characters.

  Extraction walks decoded claims and yields the role only when the target is
  a non-empty JSON string — the same rule the default `role` claim always had.
  """

  @type filter_op :: :eq | :not_eq | :starts_with | :ends_with | :contains
  @type exp :: {:key, String.t()} | {:idx, non_neg_integer()} | {:filter, filter_op(), String.t()}
  @type path :: [exp()]

  # Bare keys mirror parsec's `alphaNum <|> oneOf "_$@"`; Haskell's isAlphaNum
  # is Unicode-aware, hence the \p classes.
  @bare_key ~r/^[\p{L}\p{N}_$@]+/u
  @index ~r/^\[([0-9]+)\]/

  @doc """
  Parse a role-claim-key expression. Returns `{:ok, path}` or
  `{:error, message}` with PostgREST's pinned message (case 1711).
  """
  @spec parse(String.t()) :: {:ok, path()} | {:error, String.t()}
  def parse(input) when is_binary(input) do
    case do_parse(input, []) do
      {:ok, path} -> {:ok, path}
      :error -> {:error, "failed to parse role-claim-key value (#{input})"}
    end
  end

  # many1: an empty path is invalid; a filter must have consumed to the end.
  defp do_parse("", []), do: :error
  defp do_parse("", acc), do: {:ok, Enum.reverse(acc)}

  defp do_parse(rest, acc) do
    case expression(rest) do
      {:ok, {:filter, _, _} = filter, ""} -> do_parse("", [filter | acc])
      {:ok, {:filter, _, _}, _rest} -> :error
      {:ok, exp, rest} -> do_parse(rest, [exp | acc])
      :error -> :error
    end
  end

  defp expression("." <> rest), do: key(rest)
  defp expression("[?(" <> rest), do: filter(rest)
  defp expression("[" <> _ = rest), do: index(rest)
  defp expression(_other), do: :error

  defp key(~s(") <> _ = rest) do
    with {:ok, value, rest} <- quoted(rest), do: {:ok, {:key, value}, rest}
  end

  defp key(rest) do
    case Regex.run(@bare_key, rest) do
      [bare] ->
        {:ok, {:key, bare}, binary_part(rest, byte_size(bare), byte_size(rest) - byte_size(bare))}

      nil ->
        :error
    end
  end

  defp index(rest) do
    case Regex.run(@index, rest) do
      [whole, digits] ->
        {:ok, {:idx, String.to_integer(digits)},
         binary_part(rest, byte_size(whole), byte_size(rest) - byte_size(whole))}

      nil ->
        :error
    end
  end

  defp filter("@" <> rest) do
    with {:ok, op, rest} <- rest |> skip_spaces() |> operator(),
         {:ok, text, rest} <- rest |> skip_spaces() |> quoted(),
         ")]" <> rest <- rest do
      {:ok, {:filter, op, text}, rest}
    else
      _ -> :error
    end
  end

  defp filter(_other), do: :error

  # Match order mirrors parsec's try chain: `==^` before `==`.
  defp operator("==^" <> rest), do: {:ok, :ends_with, rest}
  defp operator("==" <> rest), do: {:ok, :eq, rest}
  defp operator("!=" <> rest), do: {:ok, :not_eq, rest}
  defp operator("^==" <> rest), do: {:ok, :starts_with, rest}
  defp operator("*==" <> rest), do: {:ok, :contains, rest}
  defp operator(_other), do: :error

  # `"` then anything but `"` (no escape form, exactly like pQuotedValue).
  defp quoted(~s(") <> rest) do
    case :binary.split(rest, ~s(")) do
      [content, rest] -> {:ok, content, rest}
      [_unterminated] -> :error
    end
  end

  defp quoted(_other), do: :error

  # Parsec's P.spaces accepts any isSpace character; ASCII whitespace covers
  # every realistic config value (exotic Unicode spaces inside a filter are not
  # mirrored).
  defp skip_spaces(<<c, rest::binary>>) when c in [?\s, ?\t, ?\n, ?\r, ?\v, ?\f],
    do: skip_spaces(rest)

  defp skip_spaces(rest), do: rest

  @doc """
  Render a parsed path in PostgREST's `--dump-config` canonical form
  (`dumpJSPath`): every key quoted, filters single-spaced.
  """
  @spec dump(path()) :: String.t()
  def dump(path), do: Enum.map_join(path, "", &dump_exp/1)

  defp dump_exp({:key, k}), do: ~s(.") <> String.replace(k, "\\", "\\\\") <> ~s(")
  defp dump_exp({:idx, i}), do: "[#{i}]"
  defp dump_exp({:filter, op, text}), do: ~s([?\(@ #{op_text(op)} "#{text}"\)])

  defp op_text(:eq), do: "=="
  defp op_text(:not_eq), do: "!="
  defp op_text(:starts_with), do: "^=="
  defp op_text(:ends_with), do: "==^"
  defp op_text(:contains), do: "*=="

  @doc """
  Walk the decoded claims along `path`. The role is the target value when it
  is a non-empty string; anything else (missing, wrong type, empty) is `nil`.
  A trailing filter selects the first matching string element of an array.
  """
  @spec extract(map(), path()) :: String.t() | nil
  def extract(claims, path) do
    case walk(claims, path) do
      role when is_binary(role) and role != "" -> role
      _other -> nil
    end
  end

  defp walk(value, []), do: value
  defp walk(%{} = map, [{:key, k} | rest]), do: walk(Map.get(map, k), rest)
  defp walk(list, [{:idx, i} | rest]) when is_list(list), do: walk(Enum.at(list, i), rest)

  defp walk(list, [{:filter, op, text}]) when is_list(list) do
    Enum.find(list, fn element -> is_binary(element) and matches?(op, element, text) end)
  end

  defp walk(_value, _path), do: nil

  defp matches?(:eq, element, text), do: element == text
  defp matches?(:not_eq, element, text), do: element != text
  defp matches?(:starts_with, element, text), do: String.starts_with?(element, text)
  defp matches?(:ends_with, element, text), do: String.ends_with?(element, text)
  defp matches?(:contains, element, text), do: String.contains?(element, text)
end
