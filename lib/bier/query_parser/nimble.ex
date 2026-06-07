defmodule Bier.QueryParser.Nimble do
  @moduledoc """
  An alternative, `nimble_parsec`-based implementation of the request-pipeline
  *leaf grammars* used by `Bier.QueryParser.parse_request/1`.

  This module is a drop-in alternative backend for the regex/string parsing path
  that lives in `Bier.QueryParser` (everything below the `# Request pipeline
  parsing` banner). Every public function here returns the EXACT same data
  structure as its regex twin, so it can be swapped in via the
  `:bier, :parser_backend` application env (`:regex` | `:nimble`).

  ## What is implemented in nimble_parsec

  The following leaf grammars are compiled to binary-matching clauses at compile
  time via `defparsec`/`defparsecp`:

    * `parse_json_path/1`        — `col`, `col->a->>b`, `col->0`, `col->>-3`
    * `split_op_value/1`         — `op`, `op(any|all)`, `fts(lang)`, `.value`
    * `parse_filter_expr/2`      — the `[not.]op.value` column-filter node
    * `parse_order_term/1`       — column order AND related `rel(col).dir.nulls`
    * `parse_scalar_select/1`    — `[alias:]col[::cast][->json]`
    * `valid_identifier?/1`      — `[A-Za-z_][A-Za-z0-9_ -]*`
    * `embed?/1`                 — does a select field reference an embedding?
    * `aggregate?/1`             — is a select field a `count()`/`col.fn()` agg?

  ## What is intentionally NOT (re)implemented here

  `split_top_commas/1` is a character-level, depth-tracking, quote-aware splitter.
  nimble_parsec is a parser, not a stream-rewriting splitter; a balanced
  recursive grammar would have to *parse* the bracket contents (which here we
  deliberately keep opaque — the splitter must tolerate arbitrary inner text such
  as `{1,"a,b"}`). Re-expressing it as a combinator buys nothing and loses the
  tolerant behaviour, so we delegate to the original. It is exposed here so the
  backend switch can route through this module uniformly.

  The genuinely recursive grammars (`parse_select_tree/1`, logic groups
  `and=(...)`, embed sub-selects) are likewise left in `Bier.QueryParser`: they
  recurse back through `split_top_commas/1` and the leaf parsers, so routing the
  *leaves* through this module already exercises nimble_parsec on the hot path.
  See `bench/REPORT.md` for the full assessment.
  """
  import NimbleParsec

  # A single `[\w ]` char (unicode `\w` ~ letters/digits/underscore, plus space).
  # ASCII word chars + space are matched directly; any codepoint above ASCII is
  # accepted as a unicode "letter" (faithful for all realistic identifier text —
  # the only non-ASCII inputs in scope are unicode letters).
  @word_or_space_char [?A..?Z, ?a..?z, ?0..?9, ?_, ?\s, 0x80..0x10FFFF]

  # ---------------------------------------------------------------------------
  # Shared character classes
  # ---------------------------------------------------------------------------

  # A PostgREST unquoted identifier: letter/underscore start, then
  # letters/digits/underscore/space/dash. Matches `valid_identifier?/1`'s regex
  # `^[A-Za-z_][A-Za-z0-9_ -]*$`.
  ident_start = [?A..?Z, ?a..?z, ?_]
  ident_rest = [?A..?Z, ?a..?z, ?0..?9, ?_, ?\s, ?-]

  identifier =
    ascii_char(ident_start)
    |> repeat(ascii_char(ident_rest))
    |> reduce({List, :to_string, []})

  # ---------------------------------------------------------------------------
  # valid_identifier?/1
  # ---------------------------------------------------------------------------

  defparsecp(:p_identifier, identifier |> eos())

  @doc "nimble twin of `Bier.QueryParser`'s private `valid_identifier?/1`."
  @spec valid_identifier?(String.t()) :: boolean()
  def valid_identifier?(col) when is_binary(col) do
    case p_identifier(col) do
      {:ok, [_], "", _, _, _} -> true
      _ -> false
    end
  end

  def valid_identifier?(_), do: false

  # ---------------------------------------------------------------------------
  # parse_json_path/1
  #
  #   col              -> {:ok, {col, []}}
  #   col->a->>b       -> {:ok, {col, [{:arrow, "a"}, {:arrow_text, "b"}]}}
  #
  # A json key is valid when it is a (optionally negative) integer OR matches
  # `^[\w ]+$` (unicode word chars + space). The base column is everything up to
  # the first arrow and is returned verbatim (it is validated separately by the
  # caller via valid_identifier?/1), so here we accept any run of chars that is
  # not the start of an arrow.
  # ---------------------------------------------------------------------------

  # \w in the original is unicode-aware (`/u`); [\w ]+ => word chars + space.
  # utf8_char with a guard lets us approximate `\w` for the json-key case while
  # staying in nimble_parsec.
  json_key_int =
    optional(ascii_char([?-]))
    |> ascii_char([?0..?9])
    |> repeat(ascii_char([?0..?9]))
    |> eos()

  defparsecp(:p_json_key_int, json_key_int)

  arrow_text = string("->>") |> replace(:arrow_text)
  arrow = string("->") |> replace(:arrow)

  # The base column: greedily consume everything up to the first `->`.
  base_col =
    times(
      lookahead_not(string("->"))
      |> utf8_char([]),
      min: 1
    )
    |> reduce({List, :to_string, []})

  # A json key: everything up to the next `->` (validated post-hoc).
  json_key =
    times(
      lookahead_not(string("->"))
      |> utf8_char([]),
      min: 1
    )
    |> reduce({List, :to_string, []})

  json_step =
    choice([arrow_text, arrow])
    |> concat(json_key)
    |> wrap()

  json_path =
    base_col
    |> repeat(json_step)
    |> eos()

  defparsecp(:p_json_path, json_path)

  @doc """
  nimble twin of `parse_json_path/1`.

  Returns `{:ok, {base_col, [{:arrow | :arrow_text, key}]}}` or `:error`.
  """
  @spec parse_json_path(String.t()) ::
          {:ok, {String.t(), [{:arrow | :arrow_text, String.t()}]}} | :error
  def parse_json_path(str) when is_binary(str) do
    case p_json_path(str) do
      {:ok, [col | steps], "", _, _, _} ->
        validate_json_steps(col, steps, [])

      _ ->
        :error
    end
  end

  defp validate_json_steps(col, [], acc), do: {:ok, {col, Enum.reverse(acc)}}

  defp validate_json_steps(col, [[kind, key] | rest], acc) do
    if json_key_valid?(key) do
      validate_json_steps(col, rest, [{kind, key} | acc])
    else
      :error
    end
  end

  # Mirrors the original `json_key_valid?/1`: non-empty and (an int OR `[\w ]+`).
  defp json_key_valid?(key) do
    key != "" and
      (match?({:ok, _, "", _, _, _}, p_json_key_int(key)) or word_space_only?(key))
  end

  # `^[\w ]+$` with unicode `\w` (letters, digits, underscore) + space.
  defp word_space_only?(key) do
    key
    |> String.to_charlist()
    |> Enum.all?(&word_or_space?/1)
  end

  defp word_or_space?(c) do
    # non-ASCII letters: approximate unicode \w with "is letter".
    c == ?\s or c == ?_ or
      (c >= ?0 and c <= ?9) or
      (c >= ?A and c <= ?Z) or
      (c >= ?a and c <= ?z) or
      (c > 127 and unicode_letter?(c))
  end

  defp unicode_letter?(c) do
    case String.to_charlist(String.downcase(<<c::utf8>>)) do
      [d] -> d != c or letterish?(<<c::utf8>>)
      _ -> letterish?(<<c::utf8>>)
    end
  rescue
    _ -> letterish?(<<c::utf8>>)
  end

  defp letterish?(s), do: Regex.match?(~r/^\p{L}$/u, s)

  # ---------------------------------------------------------------------------
  # split_op_value/1
  #
  #   ^([a-z]+)(\(([a-z_]+)\))?\.(.*)$   (with /s on the value)
  #   eq.5            -> {:ok, "eq", nil, "5"}
  #   eq(any).{3,4}   -> {:ok, "eq", "any", "{3,4}"}
  #   fts(en).foo     -> {:ok, "fts", "en", "foo"}
  # ---------------------------------------------------------------------------

  op_name =
    ascii_char([?a..?z])
    |> times(min: 1)
    |> reduce({List, :to_string, []})

  modifier =
    ignore(ascii_char([?(]))
    |> concat(
      ascii_char([?a..?z, ?_])
      |> times(min: 1)
      |> reduce({List, :to_string, []})
    )
    |> ignore(ascii_char([?)]))

  op_value_rest =
    ignore(ascii_char([?.]))
    |> post_traverse(:take_rest_as_value)

  split_op_value =
    op_name
    |> unwrap_and_tag(:op)
    |> optional(modifier |> unwrap_and_tag(:mod))
    |> concat(op_value_rest)

  defparsecp(:p_split_op_value, split_op_value)

  # Capture the entire remaining binary as the value (the original uses `.*` with
  # the `/s` flag, so newlines are included and nothing is re-parsed).
  defp take_rest_as_value(rest, args, context, _line, _offset) do
    {"", [{:value, rest} | args], context}
  end

  @doc """
  nimble twin of `split_op_value/1`.

  Returns `{:ok, op, modifier, value}` or `:error`. `modifier` is `nil` unless a
  `(any)`/`(all)`/`(lang)` quantifier is present.
  """
  @spec split_op_value(String.t()) :: {:ok, String.t(), String.t() | nil, String.t()} | :error
  def split_op_value(opval) when is_binary(opval) do
    case p_split_op_value(opval) do
      {:ok, parsed, "", _, _, _} ->
        {:ok, Keyword.fetch!(parsed, :op), Keyword.get(parsed, :mod),
         Keyword.fetch!(parsed, :value)}

      _ ->
        :error
    end
  end

  # ---------------------------------------------------------------------------
  # embed?/1
  #
  #   ^(?:[a-zA-Z_][\w ]*:)?[a-zA-Z_][\w ]*(?:![\w ]+)*\(
  # ---------------------------------------------------------------------------

  # `[a-zA-Z_][\w ]*` — letter/underscore start, then unicode word chars + space.
  # `\w` (unicode) is letters, digits, underscore; we add the literal space. We
  # implement the "word char" test via a post_traverse validator after greedily
  # consuming non-`!(:`-delimiter chars, mirroring the regex's `[\w ]`.
  defcombinatorp(
    :name_token,
    ascii_char([?A..?Z, ?a..?z, ?_])
    |> repeat(utf8_char(@word_or_space_char))
    |> reduce({List, :to_string, []})
  )

  embed_grammar =
    optional(parsec(:name_token) |> ignore(string(":")))
    |> concat(parsec(:name_token))
    |> repeat(ignore(string("!")) |> parsec(:name_token))
    |> ignore(string("("))

  defparsecp(:p_embed, embed_grammar)

  @doc "nimble twin of the private `embed?/1` predicate."
  @spec embed?(String.t()) :: boolean()
  def embed?(field) when is_binary(field) do
    match?({:ok, _, _rest, _, _, _}, p_embed(field))
  end

  # ---------------------------------------------------------------------------
  # aggregate?/1
  #
  #   ^(?:[a-zA-Z_][\w ]*:)?(?:([a-zA-Z_][\w ]*)\.)?([a-z_]+)\(\s*\)(::cast)?$
  #   bare name() => agg only if name in @agg_functions, else not.
  #   col.fn()    => always agg.
  # ---------------------------------------------------------------------------

  @agg_functions ~w(avg count max min sum)

  ws0 = repeat(ascii_char([?\s, ?\t]))

  agg_alias = optional(parsec(:name_token) |> ignore(string(":")))

  agg_col =
    optional(
      parsec(:name_token)
      |> ignore(string("."))
      |> tag(:col)
    )

  agg_fun =
    ascii_char([?a..?z, ?_])
    |> times(min: 1)
    |> reduce({List, :to_string, []})
    |> unwrap_and_tag(:fun)

  agg_cast =
    optional(
      ignore(string("::"))
      |> ascii_string([?A..?Z, ?a..?z, ?0..?9, ?_, ?\s], min: 1)
      |> unwrap_and_tag(:cast)
    )

  aggregate_grammar =
    agg_alias
    |> concat(agg_col)
    |> concat(agg_fun)
    |> ignore(string("("))
    |> ignore(ws0)
    |> ignore(string(")"))
    |> concat(agg_cast)
    |> eos()

  defparsecp(:p_aggregate, aggregate_grammar)

  @doc "nimble twin of the private `aggregate?/1` predicate."
  @spec aggregate?(String.t()) :: boolean()
  def aggregate?(field) when is_binary(field) do
    case p_aggregate(field) do
      {:ok, parsed, "", _, _, _} ->
        case Keyword.get(parsed, :col) do
          nil -> Keyword.fetch!(parsed, :fun) in @agg_functions
          _col -> true
        end

      _ ->
        false
    end
  end

  # ---------------------------------------------------------------------------
  # parse_scalar_select/1
  #
  #   [alias:]col[::cast][->json]   -> %{kind: :field, column:, alias:, cast:, json_path:}
  #
  # The original peels `alias:` (regex split_alias), then splits on `::` for the
  # cast, then runs parse_json_path on the remainder. We mirror that pipeline,
  # using nimble for the alias peel + json path and keeping the cast `::` split.
  # ---------------------------------------------------------------------------

  @doc """
  nimble twin of `parse_scalar_select/1`.

  Returns `{:ok, %{kind: :field, ...}}` or `{:error, {:select_parse, field}}`.
  """
  @spec parse_scalar_select(String.t()) :: {:ok, map()} | {:error, {:select_parse, String.t()}}
  def parse_scalar_select(field) when is_binary(field) do
    {col_alias, rest} = split_alias(field)

    {cast, rest} =
      case String.split(rest, "::", parts: 2) do
        [r, c] -> {String.trim(c), String.trim(r)}
        [r] -> {nil, String.trim(r)}
      end

    with {:ok, {col, json_path}} <- parse_json_path(rest),
         true <- valid_identifier?(col) do
      {:ok, %{kind: :field, column: col, alias: col_alias, cast: cast, json_path: json_path}}
    else
      _ -> {:error, {:select_parse, field}}
    end
  end

  # Split a leading `alias:` (not a `::` cast) off the front of a term, using a
  # nimble grammar: `name` (no `::` directly after) then `:` then the rest.
  # `[a-zA-Z_][\w ]*` — same character class as the regex alias group, consumed
  # greedily; the trailing `lookahead_not("::")` + `:` then anchors the boundary.
  alias_name =
    ascii_char([?A..?Z, ?a..?z, ?_])
    |> repeat(utf8_char(@word_or_space_char))
    |> reduce({List, :to_string, []})

  alias_peel =
    alias_name
    |> unwrap_and_tag(:name)
    |> lookahead_not(string("::"))
    |> ignore(string(":"))
    |> lookahead_not(string(":"))
    |> post_traverse(:capture_alias_rest)

  defparsecp(:p_alias, alias_peel)

  defp capture_alias_rest(rest, args, context, _line, _offset) do
    {"", [{:rest, rest} | args], context}
  end

  @doc false
  @spec split_alias(String.t()) :: {String.t() | nil, String.t()}
  def split_alias(field) when is_binary(field) do
    case p_alias(field) do
      {:ok, parsed, "", _, _, _} ->
        rest = Keyword.fetch!(parsed, :rest)
        a = Keyword.fetch!(parsed, :name)

        # The regex requires a non-empty rest `(.+)$`. If rest is empty, no alias.
        if rest == "" do
          {nil, field}
        else
          {String.trim(a), rest}
        end

      _ ->
        {nil, field}
    end
  end

  # ---------------------------------------------------------------------------
  # parse_filter_expr/2  (column filter node)
  #
  #   [not.]op.value against a (possibly json-path) column.
  # ---------------------------------------------------------------------------

  @doc """
  nimble twin of `parse_filter_expr/2`.

  Returns `{:ok, %{column:, json_path:, op:, modifier:, negate:, value:}}` or
  `:error`.
  """
  @spec parse_filter_expr(String.t(), String.t()) :: {:ok, map()} | :error
  def parse_filter_expr(col_raw, opval) when is_binary(col_raw) and is_binary(opval) do
    {negate?, opval} =
      case String.split(opval, ".", parts: 2) do
        ["not", rest] -> {true, rest}
        _ -> {false, opval}
      end

    with {:ok, {col, json_path}} <- parse_json_path(String.trim(col_raw)),
         true <- valid_identifier?(col),
         {:ok, op, modifier, value} <- split_op_value(opval) do
      {:ok,
       %{
         column: col,
         json_path: json_path,
         op: op,
         modifier: modifier,
         negate: negate?,
         value: value
       }}
    else
      _ -> :error
    end
  end

  # ---------------------------------------------------------------------------
  # parse_order_term/1
  #
  #   column order:  <col>[->json][.asc|.desc][.nullsfirst|.nullslast]
  #   related order: <rel>(<col>[->json])[.dir][.nulls]
  #
  # The original distinguishes related order with the regex
  #   ^([a-zA-Z_][\w ]*)\((.+)\)((?:\.[a-z]+)*)$
  # We reproduce that split in nimble, then run the same modifier/json-path
  # validation pipeline.
  # ---------------------------------------------------------------------------

  # Grammar: `<rel> (` where `<rel>` is `[a-zA-Z_][\w ]*`. Everything from the
  # first `(` onward is captured verbatim as `:tail` and split (inner vs mods)
  # in Elixir, reproducing the regex's greedy `(.+)` inner + `(\.[a-z]+)*` mods.
  related_head =
    ascii_char([?A..?Z, ?a..?z, ?_])
    |> repeat(utf8_char(@word_or_space_char))
    |> reduce({List, :to_string, []})
    |> unwrap_and_tag(:rel)
    |> ignore(string("("))
    |> post_traverse(:capture_related_tail)

  defparsecp(:p_related_order, related_head)

  # Capture the binary after `rel(` (i.e. `<inner>)<mods>`) for Elixir-side split.
  defp capture_related_tail(rest, args, context, _line, _offset) do
    {"", [{:tail, rest} | args], context}
  end

  @doc """
  nimble twin of `parse_order_term/1`.

  Returns `{:ok, term}` (column or related order map) or
  `{:error, {:order_parse, ...}}`.
  """
  @spec parse_order_term(String.t()) :: {:ok, map()} | {:error, term()}
  def parse_order_term(term) when is_binary(term) do
    case p_related_order(term) do
      {:ok, parsed, "", _, _, _} ->
        rel = Keyword.fetch!(parsed, :rel)
        tail = Keyword.fetch!(parsed, :tail)

        case rsplit_related(tail) do
          {:ok, inner, mods} ->
            parse_related_order_term(String.trim(rel), String.trim(inner), mods)

          :error ->
            parse_column_order_term(term)
        end

      _ ->
        parse_column_order_term(term)
    end
  end

  # `tail` = `<inner>)<mods>` where `mods` is `(\.[a-z]+)*` and inner is greedy
  # `.+`. Reproduce the regex: find the LAST `)` such that everything after it is
  # `(\.[a-z]+)*`, take inner = before it (non-empty), mods = after it.
  defp rsplit_related(tail) do
    indices =
      tail
      |> String.to_charlist()
      |> Enum.with_index()
      |> Enum.filter(fn {c, _i} -> c == ?) end)
      |> Enum.map(fn {_c, i} -> i end)
      |> Enum.reverse()

    Enum.find_value(indices, :error, fn i ->
      inner = String.slice(tail, 0, i)
      mods = String.slice(tail, (i + 1)..-1//1) || ""

      if inner != "" and valid_order_mods?(mods) do
        {:ok, inner, mods}
      else
        nil
      end
    end)
  end

  # `mods` matches `(\.[a-z]+)*`.
  defp valid_order_mods?(""), do: true
  defp valid_order_mods?(mods), do: Regex.match?(~r/^(?:\.[a-z]+)+$/, mods)

  defp parse_column_order_term(term) do
    parts = String.split(term, ".")
    {col_part, modifiers} = {hd(parts), tl(parts)}

    with {:ok, {col, json_path}} <- parse_json_path(col_part),
         true <- valid_identifier?(col),
         {:ok, dir, nulls} <- parse_order_modifiers(modifiers) do
      {:ok, %{column: col, json_path: json_path, dir: dir, nulls: nulls}}
    else
      _ -> order_error(term)
    end
  end

  defp parse_related_order_term(rel, inner, mods) do
    modifiers = mods |> String.split(".", trim: true)

    with true <- valid_identifier?(rel),
         {:ok, {col, json_path}} <- parse_json_path(inner),
         true <- valid_identifier?(col),
         {:ok, dir, nulls} <- parse_order_modifiers(modifiers) do
      {:ok, %{relation: rel, column: col, json_path: json_path, dir: dir, nulls: nulls}}
    else
      _ -> order_error(rel <> "(" <> inner <> ")" <> mods)
    end
  end

  # ---- order helpers (delegated verbatim from the original via shared logic) --

  defp parse_order_modifiers([]), do: {:ok, :asc, :default}

  defp parse_order_modifiers([m]) do
    cond do
      m in ["asc", "desc"] -> {:ok, String.to_atom(m), :default}
      m == "nullsfirst" -> {:ok, :asc, :first}
      m == "nullslast" -> {:ok, :asc, :last}
      true -> :error
    end
  end

  defp parse_order_modifiers([dir, nulls]) when dir in ["asc", "desc"] do
    case nulls do
      "nullsfirst" -> {:ok, String.to_atom(dir), :first}
      "nullslast" -> {:ok, String.to_atom(dir), :last}
      _ -> :error
    end
  end

  defp parse_order_modifiers(_), do: :error

  # The error-envelope computation is identical to the original; it depends only
  # on string ops, so we delegate to the shared regex implementation to guarantee
  # byte-identical error columns/details.
  defp order_error(term), do: Bier.QueryParser.order_error(term)

  # ---------------------------------------------------------------------------
  # split_top_commas/1 — delegated (see moduledoc).
  # ---------------------------------------------------------------------------

  @doc false
  @spec split_top_commas(String.t()) :: [String.t()]
  def split_top_commas(str), do: Bier.QueryParser.split_top_commas(str)
end
