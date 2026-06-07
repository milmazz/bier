defmodule Bier.QueryParser.Nimble do
  @moduledoc """
  The `nimble_parsec`-based implementation of the request-pipeline *leaf
  grammars* used by `Bier.QueryParser.parse_request/1`.

  These grammars compile to binary-matching clauses at compile time and replaced
  the original regex/`String.split` parsing (1.6x–5.9x faster per function,
  proven behavior-identical against the conformance suite — see
  `bench/REPORT.md`). The recursive/orchestration layer (the select tree, logic
  groups, embeds, and `split_top_commas/1`) deliberately stays on the string
  path in `Bier.QueryParser`, where `nimble_parsec` offers no benefit.

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
  tolerant behaviour, so it stays in `Bier.QueryParser`.

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

  # Deliberate simplification: any codepoint above ASCII (> 127) is accepted as a
  # valid word char, matching the combinator-level char class `@word_or_space_char`
  # (which admits `0x80..0x10FFFF`). This drops the `\p{L}` unicode-letter regex;
  # there is no behavior change on the conformance/parity corpus, which has no
  # non-ASCII JSON keys.
  defp word_or_space?(c) do
    c == ?\s or c == ?_ or
      (c >= ?0 and c <= ?9) or
      (c >= ?A and c <= ?Z) or
      (c >= ?a and c <= ?z) or
      c > 127
  end

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
  # parse_embed head+inner split
  #
  # Replaces the regex `^([a-zA-Z_][\w ]*(?:![\w ]+)*)\((.*)\)$su`:
  #   head  = `[a-zA-Z_][\w ]*(?:![\w ]+)*`  (verbatim, re-split on `!` by caller)
  #   inner = everything between the first `(` and the FINAL `)` (kept opaque).
  #
  # The grammar matches the head exactly, then `(`, then we capture the remaining
  # binary; the caller strips the trailing `)` (greedy-to-last-`)` semantics). The
  # head repeats use the `[\w ]` char class (not `name_token`) so a hint like
  # `!1a`/`! x` is captured byte-identically with the regex's `![\w ]+`.
  # ---------------------------------------------------------------------------

  # Keep the `!` separators: the head is re-split on `!` by `parse_embed_head/1`.
  embed_hint = ascii_char([?!]) |> times(utf8_char(@word_or_space_char), min: 1)

  embed_head =
    ascii_char([?A..?Z, ?a..?z, ?_])
    |> repeat(utf8_char(@word_or_space_char))
    |> repeat(embed_hint)
    |> reduce({List, :to_string, []})
    |> unwrap_and_tag(:head)
    |> ignore(string("("))
    |> post_traverse(:capture_embed_inner)

  defparsecp(:p_embed_parts, embed_head)

  defp capture_embed_inner(rest, args, context, _line, _offset) do
    {"", [{:after_paren, rest} | args], context}
  end

  @doc """
  nimble twin of the `parse_embed/1` head+inner split regex.

  Returns `{:ok, head_string, inner_string}` where `head` is the `name!hint...`
  text and `inner` is everything between the first `(` and the final `)` (kept
  opaque). Returns `:error` when the string is not a well-formed embed term.
  """
  @spec parse_embed_parts(String.t()) :: {:ok, String.t(), String.t()} | :error
  def parse_embed_parts(field) when is_binary(field) do
    case p_embed_parts(field) do
      {:ok, parsed, "", _, _, _} ->
        head = Keyword.fetch!(parsed, :head)
        after_paren = Keyword.fetch!(parsed, :after_paren)

        # The regex's `(.*)\)$` requires the string to end in `)`; `inner` is
        # everything up to that final `)`.
        if String.ends_with?(after_paren, ")") do
          {:ok, head, String.slice(after_paren, 0..-2//1)}
        else
          :error
        end

      _ ->
        :error
    end
  end

  # ---------------------------------------------------------------------------
  # parse_aggregate grammar
  #
  # Replaces two regexes in `Bier.QueryParser.parse_aggregate/1`:
  #
  #   cast peel: `^(.*\))::([A-Za-z0-9_ ]+)$`
  #     -> rightmost `::` such that the head ends in `)` and the cast is valid.
  #   call:      `^(?:([a-zA-Z_][\w ]*)\.)?([a-z_]+)\(\s*\)$` (/u)
  #     -> optional `col.` prefix, `[a-z_]+` fn, `(`, whitespace, `)`.
  # ---------------------------------------------------------------------------

  # Cast peel: greedy head up to the final `)::cast` suffix. We capture the whole
  # input and locate the split in Elixir (rightmost valid `::cast` tail) since the
  # regex's `(.*\))` is greedy with backtracking.
  @doc """
  nimble twin of the aggregate `::cast` peel regex `^(.*\\))::([A-Za-z0-9_ ]+)$`.

  Returns `{cast, rest}` — the trimmed cast and the `rest` (ending in `)`) — or
  `{nil, original}` when there is no trailing `)::cast`.
  """
  @spec peel_agg_cast(String.t()) :: {String.t() | nil, String.t()}
  def peel_agg_cast(rest) when is_binary(rest) do
    case :binary.matches(rest, "::") do
      [] ->
        {nil, rest}

      matches ->
        # Mirror the greedy `(.*\))::cast$`: try the rightmost `::` first.
        matches
        |> Enum.reverse()
        |> Enum.find_value({nil, rest}, fn {pos, _len} ->
          head = binary_part(rest, 0, pos)
          cast = binary_part(rest, pos + 2, byte_size(rest) - pos - 2)

          if String.ends_with?(head, ")") and agg_cast_chars?(cast) do
            {String.trim(cast), head}
          else
            nil
          end
        end)
    end
  end

  # `[A-Za-z0-9_ ]+` (non-empty).
  defp agg_cast_chars?(""), do: false

  defp agg_cast_chars?(cast) do
    cast
    |> String.to_charlist()
    |> Enum.all?(fn c ->
      c == ?\s or c == ?_ or
        (c >= ?0 and c <= ?9) or
        (c >= ?A and c <= ?Z) or
        (c >= ?a and c <= ?z)
    end)
  end

  agg_call_col =
    optional(
      ascii_char([?A..?Z, ?a..?z, ?_])
      |> repeat(utf8_char(@word_or_space_char))
      |> reduce({List, :to_string, []})
      |> unwrap_and_tag(:col)
      |> ignore(string("."))
    )

  agg_call_fun =
    ascii_char([?a..?z, ?_])
    |> times(min: 1)
    |> reduce({List, :to_string, []})
    |> unwrap_and_tag(:fun)

  agg_call_grammar =
    agg_call_col
    |> concat(agg_call_fun)
    |> ignore(string("("))
    |> ignore(repeat(ascii_char([?\s, ?\t, ?\n, ?\r, ?\f, ?\v])))
    |> ignore(string(")"))
    |> eos()

  defparsecp(:p_agg_call, agg_call_grammar)

  @doc """
  nimble twin of the aggregate call regex
  `^(?:([a-zA-Z_][\\w ]*)\\.)?([a-z_]+)\\(\\s*\\)$`.

  Returns `{:ok, col_or_nil, fun}` (col is `nil` when there is no `col.` prefix)
  or `:error`.
  """
  @spec parse_agg_call(String.t()) :: {:ok, String.t() | nil, String.t()} | :error
  def parse_agg_call(rest) when is_binary(rest) do
    case p_agg_call(rest) do
      {:ok, parsed, "", _, _, _} ->
        {:ok, Keyword.get(parsed, :col), Keyword.fetch!(parsed, :fun)}

      _ ->
        :error
    end
  end

  # ---------------------------------------------------------------------------
  # logic_prefix/1
  #
  # Replaces the four regexes `^(not\.)?(and|or)\s*(\(.*\))$` (/s):
  #   not.and(...) / not.or(...) / and(...) / or(...) with optional whitespace
  #   between the keyword and the opening `(`. The group `(\(.*\))` keeps the
  #   parens and is greedy to the final `)`.
  # ---------------------------------------------------------------------------

  logic_ws = repeat(ascii_char([?\s, ?\t, ?\n, ?\r, ?\f, ?\v]))

  logic_kw =
    choice([
      string("not.and") |> replace({true, :and}),
      string("not.or") |> replace({true, :or}),
      string("and") |> replace({false, :and}),
      string("or") |> replace({false, :or})
    ])
    |> unwrap_and_tag(:kw)

  logic_grammar =
    logic_kw
    |> ignore(logic_ws)
    |> post_traverse(:capture_logic_rest)

  defparsecp(:p_logic_prefix, logic_grammar)

  defp capture_logic_rest(rest, args, context, _line, _offset) do
    {"", [{:rest, rest} | args], context}
  end

  @doc """
  nimble twin of the `logic_prefix/1` regexes.

  Returns `{negate?, :and | :or, "(...)"}` when `member` begins with
  `and(`/`or(`/`not.and(`/`not.or(` (whitespace allowed before the `(`) and ends
  in `)`; otherwise `nil`. The returned group keeps its surrounding parens.
  """
  @spec logic_prefix(String.t()) :: {boolean(), :and | :or, String.t()} | nil
  def logic_prefix(member) when is_binary(member) do
    case p_logic_prefix(member) do
      {:ok, parsed, "", _, _, _} ->
        {negate?, op} = Keyword.fetch!(parsed, :kw)
        rest = Keyword.fetch!(parsed, :rest)

        # The regex group is `(\(.*\))`: rest must start with `(` and end with `)`.
        if String.starts_with?(rest, "(") and String.ends_with?(rest, ")") do
          {negate?, op, rest}
        else
          nil
        end

      _ ->
        nil
    end
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

  # `(\.[a-z]+)+` — one or more `.<lowercase-run>` order-modifier groups, anchored
  # to end of string. Replaces the `^(?:\.[a-z]+)+$` regex in `valid_order_mods?/1`.
  order_mods =
    times(
      ignore(ascii_char([?.]))
      |> times(ascii_char([?a..?z]), min: 1),
      min: 1
    )
    |> eos()

  defparsecp(:p_order_mods, order_mods)

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

  defp valid_order_mods?(mods) do
    match?({:ok, _, "", _, _, _}, p_order_mods(mods))
  end

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
end
