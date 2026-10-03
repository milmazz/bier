defmodule Bier.JWT.RoleClaim.Deprecated do
  @moduledoc """
  The pre-v16 leading-dot JSPath DSL for `jwt-role-claim-key`, accepted again
  as **deprecated** syntax.

  PostgREST v16.0 replaced this DSL with RFC 9535 JSON Path and made it a
  startup error; v16.2 (PostgREST#5171) made the key backwards compatible
  again. `parseRoleClaimKey` (Config.hs) tries the RFC 9535 parser first and,
  only when that fails, this grammar (`PostgREST.Config.DeprecatedJSPath`),
  keeping the result as a `DeprecatedJSPath`. Loading one logs a deprecation
  warning (Logger.hs `DeprecatedJSPathSyntaxObs`); upstream plans to remove
  the DSL in its next major release.

  `Bier.JWT.RoleClaim` is the entry point: it falls back here, so callers
  never use this module directly. The grammar, mirroring upstream's Parsec
  parser:

    * one or more expressions, then end of input;
    * a key: `.` then one or more letters, digits, `_`, `$` or `@`
      (`.realm_access`), or a double-quoted string with no `"` inside
      (`."https://example.com/roles"`);
    * an index: `[` decimal digits `]` (no sign);
    * a filter, only as the LAST expression: `[?(@ <op> "<text>")]` with
      optional whitespace around the operator, where the operator is one of
      `==` (equals), `!=` (not equals), `^==` (starts with), `==^` (ends
      with) or `*==` (contains).

  Evaluation walks the claims one expression at a time — a key on an object,
  an index on an array — and a filter returns the FIRST string element of an
  array that matches (`evaluateDeprecatedJSPath`). Anything else selects
  nothing.

  ## Dump

  `dump/1` renders every key quoted and leaves a filter as written
  (`.roles.user_role` -> `."roles"."user_role"`), the spelling upstream's
  `--dump-config` and its deprecation warning use. Upstream quotes with
  Haskell's `show`, which also escapes `\\` and every non-ASCII character
  (its own source carries a "needs to be quoted properly" TODO): the result
  no longer re-parses to the same key, since this grammar has no escapes.
  Bier wraps the text in `"` verbatim instead — always valid, because a key
  or filter text can never contain `"` — so its dump re-parses to the same
  path (the config round trip `Bier.CLI.Config` relies on). The two agree
  byte for byte on every key made of printable ASCII without `\\`.
  """

  @type op :: :eq | :ne | :starts_with | :ends_with | :contains

  @type expression ::
          {:key, String.t()} | {:index, non_neg_integer()} | {:filter, op(), String.t()}

  @type path :: [expression(), ...]

  # Parsec's `alphaNum` is Data.Char.isAlphaNum: Unicode letters and numbers.
  @bare_key ~r/^[\p{L}\p{N}_$@]+/u
  @index ~r/^\[([0-9]+)\]/

  # `matchOperator`'s order: `==^` must be tried before its `==` prefix.
  @operators [
    {"==^", :ends_with},
    {"==", :eq},
    {"!=", :ne},
    {"^==", :starts_with},
    {"*==", :contains}
  ]

  @doc """
  Parse a deprecated JSPath. Returns `{:ok, path}` or `:error`; the caller
  owns the error message (upstream reports the fallback's failure under the
  same "failed to parse role-claim-key value" label).
  """
  @spec parse(String.t()) :: {:ok, path()} | :error
  def parse(input) when is_binary(input) do
    case expressions(input, []) do
      {:ok, [_ | _] = path} -> {:ok, path}
      _other -> :error
    end
  end

  defp expressions("", acc), do: {:ok, Enum.reverse(acc)}

  defp expressions(input, acc) do
    case expression(input) do
      {:ok, exp, rest} -> expressions(rest, [exp | acc])
      :error -> :error
    end
  end

  defp expression("." <> rest) do
    case Regex.run(@bare_key, rest) do
      [key] -> {:ok, {:key, key}, consume(rest, key)}
      nil -> quoted_key(rest)
    end
  end

  # A filter must be the last expression (`pJSPFilter` ends in `P.eof`).
  defp expression("[?(" <> rest) do
    with "@" <> rest <- rest,
         {:ok, op, rest} <- operator(skip_spaces(rest)),
         {:ok, text, rest} <- quoted(skip_spaces(rest)),
         ")]" <- rest do
      {:ok, {:filter, op, text}, ""}
    else
      _other -> :error
    end
  end

  defp expression("[" <> _rest = input) do
    case Regex.run(@index, input) do
      [whole, digits] -> {:ok, {:index, String.to_integer(digits)}, consume(input, whole)}
      nil -> :error
    end
  end

  defp expression(_other), do: :error

  defp quoted_key(input) do
    with {:ok, key, rest} <- quoted(input), do: {:ok, {:key, key}, rest}
  end

  defp quoted("\"" <> rest) do
    case :binary.split(rest, "\"") do
      [text, rest] -> {:ok, text, rest}
      [_unterminated] -> :error
    end
  end

  defp quoted(_other), do: :error

  defp operator(input) do
    Enum.find_value(@operators, :error, fn {text, op} ->
      if String.starts_with?(input, text), do: {:ok, op, consume(input, text)}
    end)
  end

  # Parsec's `spaces` skips any Data.Char.isSpace character.
  defp skip_spaces(input), do: String.replace(input, ~r/^\s+/u, "")

  defp consume(input, taken),
    do: binary_part(input, byte_size(taken), byte_size(input) - byte_size(taken))

  @doc """
  Render a parsed path the way upstream's `dumpDeprecatedJSPath` does: keys
  quoted, indexes bare, the filter as `[?(@ <op> "<text>")]`. See the
  moduledoc for the one deliberate difference in quoting.
  """
  @spec dump(path()) :: String.t()
  def dump(path), do: Enum.map_join(path, "", &dump_expression/1)

  defp dump_expression({:key, key}), do: ~s(."#{key}")
  defp dump_expression({:index, index}), do: "[#{index}]"
  defp dump_expression({:filter, op, text}), do: ~s{[?(@ #{op_text(op)} "#{text}")]}

  defp op_text(:eq), do: "=="
  defp op_text(:ne), do: "!="
  defp op_text(:starts_with), do: "^=="
  defp op_text(:ends_with), do: "==^"
  defp op_text(:contains), do: "*=="

  @doc """
  Evaluate `path` against the decoded claims (`evaluateDeprecatedJSPath`).
  Returns `{:ok, value}` for the selected JSON value, or `:error` when the
  path selects nothing.
  """
  @spec evaluate(map(), path()) :: {:ok, term()} | :error
  def evaluate(claims, path), do: walk({:ok, claims}, path)

  defp walk(found, []), do: found

  defp walk({:ok, object}, [{:key, key} | rest]) when is_map(object),
    do: walk(Map.fetch(object, key), rest)

  defp walk({:ok, array}, [{:index, index} | rest]) when is_list(array),
    do: walk(Enum.fetch(array, index), rest)

  defp walk({:ok, array}, [{:filter, op, text}]) when is_list(array) do
    case Enum.find(array, &(is_binary(&1) and matches?(op, text, &1))) do
      nil -> :error
      value -> {:ok, value}
    end
  end

  defp walk(_found, _path), do: :error

  defp matches?(:eq, text, value), do: value == text
  defp matches?(:ne, text, value), do: value != text
  defp matches?(:starts_with, text, value), do: String.starts_with?(value, text)
  defp matches?(:ends_with, text, value), do: String.ends_with?(value, text)
  defp matches?(:contains, text, value), do: String.contains?(value, text)
end
