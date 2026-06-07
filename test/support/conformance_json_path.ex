defmodule Bier.ConformanceJsonPath do
  @moduledoc """
  A deterministic, single-match JSONPath subset for the conformance harness's
  `expect.body_jsonpath` assertions.

  Supports exactly the grammar the conformance cases use — root `$`, dot member
  `.key`, bracket string key `['key']` (keys may contain `/`, `$`, digits), and
  array index `[n]`. It deliberately does NOT support filters (`?()`), recursive
  descent (`..`), wildcards (`[*]`/`.*`), or slices; such syntax raises rather
  than being silently ignored. Inputs are trusted (our own checked-in spec
  files), so the parser fails fast on a malformed path to surface authoring
  typos at the assertion site.
  """

  @type segment :: {:key, String.t()} | {:index, non_neg_integer()}

  @doc """
  Parse a path string into a list of segments. Raises `ArgumentError` on a
  malformed path. `"$"` parses to `[]` (the whole document).
  """
  @spec parse(String.t()) :: [segment()]
  def parse("$" <> rest), do: parse_segments(rest, [], "$" <> rest)
  def parse(path), do: raise(ArgumentError, "JSONPath must start with $: #{inspect(path)}")

  defp parse_segments("", acc, _orig), do: Enum.reverse(acc)

  # .identifier
  defp parse_segments("." <> rest, acc, orig) do
    {ident, rest} = take_ident(rest, "")
    if ident == "", do: bad(orig)
    parse_segments(rest, [{:key, ident} | acc], orig)
  end

  # ['quoted string']  (must be tried before the bare-"[" clause below)
  defp parse_segments("['" <> rest, acc, orig) do
    case take_until_quote(rest, "") do
      {"", _} -> bad(orig)
      {key, "]" <> rest2} -> parse_segments(rest2, [{:key, key} | acc], orig)
      _ -> bad(orig)
    end
  end

  # [integer]
  defp parse_segments("[" <> rest, acc, orig) do
    case take_digits(rest, "") do
      {"", _} ->
        bad(orig)

      {digits, "]" <> rest2} ->
        parse_segments(rest2, [{:index, String.to_integer(digits)} | acc], orig)

      _ ->
        bad(orig)
    end
  end

  defp parse_segments(_other, _acc, orig), do: bad(orig)

  defp take_ident(<<c, rest::binary>>, acc)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_,
       do: take_ident(rest, acc <> <<c>>)

  defp take_ident(rest, acc), do: {acc, rest}

  defp take_digits(<<c, rest::binary>>, acc) when c in ?0..?9,
    do: take_digits(rest, acc <> <<c>>)

  defp take_digits(rest, acc), do: {acc, rest}

  # Read until the closing single quote. No escaping is needed for the corpus;
  # an unterminated quote returns :unterminated, which the caller turns into a
  # parse error.
  defp take_until_quote("'" <> rest, acc), do: {acc, rest}
  defp take_until_quote(<<c, rest::binary>>, acc), do: take_until_quote(rest, acc <> <<c>>)
  defp take_until_quote("", _acc), do: :unterminated

  defp bad(orig), do: raise(ArgumentError, "malformed JSONPath: #{inspect(orig)}")
end
