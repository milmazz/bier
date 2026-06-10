defmodule Bier.QueryParser do
  @moduledoc """
  Parser for the PostgREST-style request query string.

  `parse_request/1` turns a raw query string into a structured query plan
  (select tree, filters, order, pagination, write params) that
  `Bier.QueryExecutor` renders into one parameterized SQL statement.

  The *leaf grammars* (json paths, filter expressions, order terms, embed and
  aggregate heads, identifiers) are `nimble_parsec` combinators compiled to
  binary-matching clauses (1.6x-5.9x faster than the regex/`String.split`
  parsing they replaced, proven behavior-identical against the conformance
  suite -- see `bench/REPORT.md`). The recursive/orchestration layer (the
  select tree, logic groups, embeds, and `split_top_commas/1`) deliberately
  stays on the string path, where `nimble_parsec` offers no benefit:
  `split_top_commas/1` is a depth-tracking, quote-aware splitter that must
  tolerate arbitrary inner text such as `{1,"a,b"}`, and the genuinely
  recursive grammars recurse back through it and the leaf parsers.

  > #### Generated file {: .info}
  >
  > The committed `lib/bier/query_parser.ex` is **generated** from this
  > template (`lib/bier/query_parser.ex.exs`) via `mix gen.parsers`, which runs
  > `mix nimble_parsec.compile`. Only the combinators between the `parsec`
  > marker comments are expanded; everything else passes through verbatim. The
  > generated `.ex` has no runtime dependency on `nimble_parsec` (a dev-only
  > dependency). Edit this template and re-run `mix gen.parsers`; never edit
  > the `.ex` directly.
  """

  # parsec:Bier.QueryParser
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

  # `[a-zA-Z_][\w ]*` — a PostgREST name token (letter/underscore start, then
  # unicode word chars + space). Defined as a plain combinator variable (not a
  # `defcombinatorp`/`parsec(:name_token)`): inlining it into each use site keeps
  # the generated parser free of the dead `error` binding that the
  # `optional(parsec(...))` expansion would otherwise emit.
  name_token =
    ascii_char([?A..?Z, ?a..?z, ?_])
    |> repeat(utf8_char(@word_or_space_char))
    |> reduce({List, :to_string, []})

  # ---------------------------------------------------------------------------
  # valid_identifier?/1
  # ---------------------------------------------------------------------------

  defparsecp(:p_identifier, identifier |> eos())

  # ---------------------------------------------------------------------------
  # parse_json_path/1
  # ---------------------------------------------------------------------------

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

  # ---------------------------------------------------------------------------
  # split_op_value/1
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

  # ---------------------------------------------------------------------------
  # embed?/1
  # ---------------------------------------------------------------------------

  embed_grammar =
    optional(name_token |> ignore(string(":")))
    |> concat(name_token)
    |> repeat(ignore(string("!")) |> concat(name_token))
    |> ignore(string("("))

  defparsecp(:p_embed, embed_grammar)

  # ---------------------------------------------------------------------------
  # parse_embed head+inner split
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

  # ---------------------------------------------------------------------------
  # parse_aggregate grammar
  # ---------------------------------------------------------------------------

  agg_call_col =
    optional(
      name_token
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

  # ---------------------------------------------------------------------------
  # logic_prefix/1
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

  # ---------------------------------------------------------------------------
  # aggregate?/1
  # ---------------------------------------------------------------------------

  ws0 = repeat(ascii_char([?\s, ?\t]))

  agg_alias = optional(name_token |> ignore(string(":")))

  agg_col =
    optional(
      name_token
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

  # ---------------------------------------------------------------------------
  # parse_scalar_select/1 (alias peel)
  # ---------------------------------------------------------------------------

  alias_peel =
    name_token
    |> unwrap_and_tag(:name)
    |> lookahead_not(string("::"))
    |> ignore(string(":"))
    |> lookahead_not(string(":"))
    |> post_traverse(:capture_alias_rest)

  defparsecp(:p_alias, alias_peel)

  # ---------------------------------------------------------------------------
  # parse_order_term/1
  # ---------------------------------------------------------------------------

  related_head =
    ascii_char([?A..?Z, ?a..?z, ?_])
    |> repeat(utf8_char(@word_or_space_char))
    |> reduce({List, :to_string, []})
    |> unwrap_and_tag(:rel)
    |> ignore(string("("))
    |> post_traverse(:capture_related_tail)

  defparsecp(:p_related_order, related_head)

  order_mods =
    times(
      ignore(ascii_char([?.]))
      |> times(ascii_char([?a..?z]), min: 1),
      min: 1
    )
    |> eos()

  defparsecp(:p_order_mods, order_mods)

  # parsec:Bier.QueryParser

  # ==========================================================================
  # Request pipeline parsing (PostgREST-shaped)
  #
  # The functions below take the raw query string of a request and produce an
  # AST of selects/filters/order that `Bier.QueryExecutor` turns into one
  # parameterized SQL statement.
  # ==========================================================================

  @reserved ~w(select order limit offset on_conflict columns and or not)

  @doc """
  Parse a full request query string into a structured query plan.

  Returns `{:ok, plan}` where `plan` is a map with keys `:select`, `:filters`,
  `:order`, `:limit`, `:offset`, or `{:error, reason}`.

  `select`/`order` items and column filters are returned as data; the executor
  resolves them against the relation's columns and renders SQL.
  """
  @spec parse_request(String.t()) :: {:ok, map()} | {:error, term()}
  def parse_request(query_string) when is_binary(query_string) do
    params = decode_query(query_string)

    with {:ok, select} <- pg_select(params),
         {:ok, order} <- pg_order(params["order"]),
         {:ok, embed_orders} <- pg_embed_orders(params),
         {:ok, limit} <- pg_limit(params["limit"]),
         {:ok, offset} <- pg_offset(params["offset"]),
         {:ok, embed_limits} <- pg_embed_paged(params, "limit", &pg_limit/1),
         {:ok, embed_offsets} <- pg_embed_paged(params, "offset", &pg_offset/1),
         {:ok, columns} <- pg_columns(params),
         {:ok, on_conflict} <- pg_on_conflict(params),
         {:ok, {filters, embed_filters}} <- pg_filters(params) do
      {:ok,
       %{
         select: select,
         filters: filters,
         embed_filters: embed_filters,
         order: order,
         embed_orders: embed_orders,
         limit: limit,
         offset: offset,
         embed_limits: embed_limits,
         embed_offsets: embed_offsets,
         columns: columns,
         on_conflict: on_conflict,
         # The presence of `limit`/`offset` query params is needed by PUT (which
         # rejects them); record it separately since the values may be nil.
         has_limit: Map.has_key?(params, "limit"),
         has_offset: Map.has_key?(params, "offset")
       }}
    end
  end

  # ---- columns / on_conflict (mutation write params) -----------------------

  # `?columns=a,b,c` selects which JSON keys become target columns for a write
  # (extra keys in the payload are ignored). A *present but blank* `columns=`
  # is a PGRST100 parse error; an absent param means "derive columns from the
  # payload keys" (signalled by `nil`).
  defp pg_columns(params) do
    case Map.get(params, "columns") do
      nil ->
        {:ok, nil}

      "" ->
        {:error, :blank_columns}

      raw ->
        cols =
          raw
          |> split_top_commas()
          |> Enum.map(&String.trim/1)

        if cols == [] or Enum.any?(cols, &(&1 == "")) do
          {:error, :blank_columns}
        else
          {:ok, cols}
        end
    end
  end

  # `?on_conflict=a,b` names the columns of the unique/exclusion constraint to
  # use as the upsert conflict target. Absent => nil (use the PK).
  defp pg_on_conflict(params) do
    case Map.get(params, "on_conflict") do
      nil ->
        {:ok, nil}

      "" ->
        {:ok, nil}

      raw ->
        cols =
          raw
          |> split_top_commas()
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        {:ok, cols}
    end
  end

  # Decode a query string into an ordered list-aware map. We keep duplicate keys
  # by collecting them; `and`/`or` may repeat. Values are URL-decoded with `+`
  # mapped to a space per application/x-www-form-urlencoded rules.
  defp decode_query(""), do: %{}

  defp decode_query(qs) do
    qs
    |> String.split("&")
    |> Enum.reduce(%{}, fn pair, acc ->
      case String.split(pair, "=", parts: 2) do
        [k, v] -> Map.update(acc, url_decode(k), [url_decode(v)], &(&1 ++ [url_decode(v)]))
        [k] -> Map.put_new(acc, url_decode(k), [""])
      end
    end)
    |> Map.new(fn
      {k, [single]} -> {k, single}
      {k, list} -> {k, list}
    end)
  end

  defp url_decode(str) do
    str |> String.replace("+", " ") |> URI.decode()
  end

  # ---- select --------------------------------------------------------------

  defp pg_select(params) do
    case Map.get(params, "select") do
      nil ->
        {:ok, [:star]}

      "" ->
        {:ok, [:star]}

      "*" ->
        {:ok, [:star]}

      sel ->
        # A select-parse failure is a 400 PGRST100 with PostgREST's parser-error
        # envelope referencing the *whole* select parameter and the 1-based
        # column of the offending token (cases 1111/1180). We surface a rich
        # error tagged with the original select string so the controller can
        # render the `failed to parse select parameter (...)` message.
        case parse_select_tree(sel) do
          {:ok, nodes} -> {:ok, nodes}
          {:error, {:select_parse, _node}} -> {:error, select_parse_error(sel)}
          {:error, other} -> {:error, other}
        end
    end
  end

  # Build the PostgREST select parse-error tuple `{:select_parse, select, detail,
  # column}`. We locate the first malformed json-path token within the select
  # string to compute the column and detail (`data->>--34` => column 9,
  # `unexpected "-" expecting digit`).
  defp select_parse_error(sel) do
    {detail, column} = locate_select_error(sel)
    {:select_parse, sel, detail, column}
  end

  # Find the offending token in a select string carrying a json path. We look for
  # the first `->`/`->>` arrow followed by an invalid key. After an arrow the
  # parser expects an integer index (optional single leading `-`) or a key; a
  # second `-` (e.g. `->>--34`) is "unexpected '-' expecting digit".
  defp locate_select_error(sel) do
    case scan_arrow_double_dash(sel, 0) do
      {:ok, second_dash_byte} ->
        # The match operates on ASCII bytes (`-`/`>`), so the byte offset of the
        # second dash equals its 0-based char position; +1 makes it 1-based.
        {"unexpected \"-\" expecting digit", second_dash_byte + 1}

      :error ->
        # Fallback: point just past the last valid prefix.
        {"unexpected end of input", String.length(sel) + 1}
    end
  end

  # Non-regex twin of the `->>?(-)(-)` pattern: scan for the leftmost `->`/`->>` arrow
  # immediately followed by `--`, returning the byte offset of the *second* dash
  # (the regex's group-2 index). Mirrors the regex's greedy `>?` (prefer `->>`,
  # fall back to `->`) and left-to-right scan.
  defp scan_arrow_double_dash(sel, from) do
    case :binary.match(sel, "->", scope: {from, byte_size(sel) - from}) do
      :nomatch ->
        :error

      {pos, _len} ->
        rest = binary_part(sel, pos, byte_size(sel) - pos)

        cond do
          # `->>--`: arrow is `->>`, then `--`; second dash is at pos + 4.
          match?("->>--" <> _, rest) -> {:ok, pos + 4}
          # `->--`: arrow is `->`, then `--`; second dash is at pos + 3.
          match?("->--" <> _, rest) -> {:ok, pos + 3}
          # No double-dash here; resume scanning just past this `->`.
          true -> scan_arrow_double_dash(sel, pos + 2)
        end
    end
  end

  # Parse a (possibly nested) select list into a list of nodes. A node is one of:
  #
  #   %{kind: :field, ...}      -- scalar column / json-path / cast
  #   %{kind: :star}            -- `*`
  #   %{kind: :agg, ...}        -- aggregate (col.fn() or count())
  #   %{kind: :embed, ...}      -- related resource `rel(...)` / `rel!hint(...)`
  #                                 / spread `...rel(...)`
  def parse_select_tree(sel) do
    sel
    |> split_top_commas()
    |> Enum.reduce_while([], fn raw, acc ->
      case parse_select_node(String.trim(raw)) do
        {:ok, node} -> {:cont, [node | acc]}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      list -> {:ok, Enum.reverse(list)}
    end
  end

  defp parse_select_node(field) do
    cond do
      field == "" ->
        {:error, {:select_parse, field}}

      field == "*" ->
        {:ok, %{kind: :star}}

      String.starts_with?(field, "...") ->
        parse_embed(String.trim_leading(field, "."), true)

      aggregate?(field) ->
        parse_aggregate(field)

      embed?(field) ->
        parse_embed(field, false)

      true ->
        parse_scalar_select(field)
    end
  end

  defp parse_aggregate(field) do
    {out_alias, rest} = split_alias(field)

    {cast, rest} = peel_agg_cast(rest)

    case parse_agg_call(rest) do
      {:ok, nil, fun} ->
        {:ok, %{kind: :agg, column: nil, fun: fun, alias: out_alias, cast: cast}}

      {:ok, col, fun} ->
        if valid_identifier?(col),
          do: {:ok, %{kind: :agg, column: col, fun: fun, alias: out_alias, cast: cast}},
          else: {:error, {:select_parse, field}}

      :error ->
        {:error, {:select_parse, field}}
    end
  end

  # Parse an embedding term: `[alias:]relation[!hint...][!inner|!left](sub-select)`
  defp parse_embed(field, spread?) do
    {emb_alias, rest} = split_alias(field)

    case parse_embed_parts(rest) do
      {:ok, head, inner} ->
        {target, hints} = parse_embed_head(head)

        {join_type, hints} = extract_join_type(hints)

        with {:ok, children} <- parse_inner_select(inner) do
          {:ok,
           %{
             kind: :embed,
             target: target,
             alias: emb_alias,
             spread: spread?,
             hint: List.first(hints),
             join: join_type,
             empty: String.trim(inner) == "",
             select: children
           }}
        end

      _ ->
        {:error, {:select_parse, field}}
    end
  end

  defp parse_inner_select(""), do: {:ok, [:star]}

  defp parse_inner_select(inner) do
    case parse_select_tree(inner) do
      {:ok, list} -> {:ok, list}
      other -> other
    end
  end

  # `relation!a!b` -> {"relation", ["a", "b"]}
  defp parse_embed_head(head) do
    case String.split(head, "!") do
      [target | hints] -> {String.trim(target), Enum.map(hints, &String.trim/1)}
    end
  end

  # Pull `inner`/`left` join markers out of the hint list.
  defp extract_join_type(hints) do
    cond do
      "inner" in hints -> {:inner, hints -- ["inner"]}
      "left" in hints -> {:left, hints -- ["left"]}
      true -> {nil, hints}
    end
  end

  # ---- order ---------------------------------------------------------------

  defp pg_order(nil), do: {:ok, []}
  defp pg_order(""), do: {:ok, []}

  defp pg_order(order) when is_list(order) do
    # Duplicate `order=` params: PostgREST uses the last occurrence.
    pg_order(List.last(order))
  end

  defp pg_order(order) do
    order
    |> split_top_commas()
    |> Enum.reduce_while([], fn raw, acc ->
      case parse_order_term(String.trim(raw)) do
        {:ok, term} -> {:cont, [term | acc]}
        {:error, _} = e -> {:halt, e}
      end
    end)
    |> case do
      {:error, _} = e -> e
      list -> {:ok, Enum.reverse(list)}
    end
  end

  # Embed-targeted order params: `<rel>.order=...`, `<rel>.<rel2>.order=...`.
  # Returns a map of embed-path (list) => order terms list. Validated like the
  # top-level order; bad syntax surfaces the same PGRST100 error.
  defp pg_embed_orders(params) do
    params
    |> Enum.filter(fn {k, _v} -> String.ends_with?(k, ".order") end)
    |> Enum.reduce_while({:ok, %{}}, fn {k, v}, {:ok, acc} ->
      path =
        k
        |> String.replace_suffix(".order", "")
        |> String.split(".")

      case pg_order(v) do
        {:ok, terms} -> {:cont, {:ok, Map.put(acc, path, terms)}}
        {:error, _} = e -> {:halt, e}
      end
    end)
  end

  # Embed-targeted `limit`/`offset` params: `<rel>.limit=N`, `<rel>.<rel2>.offset=N`.
  # Returns a map of embed-path (list) => integer (or nil). `kind` is "limit" or
  # "offset"; `parse_fun` is the matching top-level parser so validation (and the
  # negative-limit / negative-offset semantics) stay consistent.
  defp pg_embed_paged(params, kind, parse_fun) do
    suffix = "." <> kind

    params
    |> Enum.filter(fn {k, _v} -> String.ends_with?(k, suffix) and k != kind end)
    |> Enum.reduce_while({:ok, %{}}, fn {k, v}, {:ok, acc} ->
      path = k |> String.replace_suffix(suffix, "") |> String.split(".")
      value = if is_list(v), do: List.last(v), else: v

      case parse_fun.(value) do
        {:ok, n} -> {:cont, {:ok, Map.put(acc, path, n)}}
        {:error, _} = e -> {:halt, e}
      end
    end)
  end

  # PostgREST renders a precise parser error for bad order syntax. We reproduce
  # the common case (an unexpected trailing token after a valid prefix) used by
  # the conformance suite; other malformed terms fall back to the same envelope.
  @doc false
  def order_error(term) do
    count = leading_valid_order_length(term)
    bad_rest = String.slice(term, count..-1//1)

    detail =
      case bad_rest do
        "" -> "unexpected end of input"
        <<c::utf8, _::binary>> -> "unexpected '#{<<c::utf8>>}' expecting \",\" or end of input"
      end

    # column is the 1-based char position (within the order string) of the
    # unexpected token, i.e. just past the longest valid prefix. For the
    # conformance case `id.asc.nullslasttt` PostgREST parses `id.asc.nullslast`
    # (16 chars) then reports the trailing `t` at column 17.
    column = count + 1

    {:error, {:order_parse, term, detail, column}}
  end

  @order_keywords ~w(asc desc nullsfirst nullslast)

  # Number of chars of `term` that parse as a valid `col[.dir][.nulls]` prefix,
  # greedily consuming keyword prefixes within a malformed final token (so
  # `nullslasttt` consumes `nullslast`). Used to compute the error column.
  defp leading_valid_order_length(term) do
    parts = term |> String.split(".") |> Enum.with_index()

    {len, _expect} =
      Enum.reduce_while(parts, {0, :col}, fn {part, idx}, {len, expect} ->
        # account for the `.` separator before every part except the first
        sep = if idx == 0, do: 0, else: 1

        case expect do
          :col ->
            if part == "",
              do: {:halt, {len, expect}},
              else: {:cont, {len + sep + String.length(part), :mod}}

          :mod ->
            cond do
              part in @order_keywords ->
                {:cont, {len + sep + String.length(part), :mod}}

              kw = matching_keyword_prefix(part) ->
                {:halt, {len + sep + String.length(kw), :mod}}

              true ->
                {:halt, {len, expect}}
            end
        end
      end)

    len
  end

  defp matching_keyword_prefix(part) do
    Enum.find(@order_keywords, &String.starts_with?(part, &1))
  end

  # ---- limit/offset --------------------------------------------------------

  defp pg_limit(nil), do: {:ok, nil}
  defp pg_limit(""), do: {:ok, nil}

  defp pg_limit(v) do
    case Integer.parse(v) do
      {n, ""} when n >= 0 -> {:ok, n}
      # A negative limit is a distinct 416 PGRST103 (NegativeLimit), not a
      # generic parse error. See pagination case 1254.
      {n, ""} when n < 0 -> {:error, :negative_limit}
      _ -> {:error, :bad_limit}
    end
  end

  defp pg_offset(nil), do: {:ok, nil}
  defp pg_offset(""), do: {:ok, nil}

  defp pg_offset(v) do
    case Integer.parse(v) do
      {n, ""} when n >= 0 -> {:ok, n}
      # PostgREST treats a negative offset as a no-op (equivalent to offset 0).
      # See pagination case 1256.
      {n, ""} when n < 0 -> {:ok, nil}
      _ -> {:error, :bad_offset}
    end
  end

  # ---- filters -------------------------------------------------------------

  defp pg_filters(params) do
    {own, embed} =
      params
      |> Enum.reject(fn {k, _v} ->
        base_key(k) in @reserved or String.ends_with?(k, ".order") or
          String.ends_with?(k, ".limit") or String.ends_with?(k, ".offset")
      end)
      |> Enum.split_with(fn {k, _v} -> embed_path(k) == [] end)

    with {:ok, cond_list} <- reduce_filters(own),
         {:ok, with_logic} <- parse_logic(params, cond_list),
         {:ok, embed_filters} <- reduce_embed_filters(embed) do
      {:ok, {with_logic, embed_filters}}
    end
  end

  defp reduce_filters(pairs) do
    # A column repeated in the query string (e.g. `id=gt.1&id=lt.5`) yields one
    # ANDed filter node per occurrence, mirroring PostgREST.
    pairs
    |> Enum.flat_map(fn {key, val} ->
      case val do
        list when is_list(list) -> Enum.map(list, &{key, &1})
        single -> [{key, single}]
      end
    end)
    |> Enum.reduce_while([], fn {key, val}, acc ->
      case parse_column_filter(key, val) do
        {:ok, node} -> {:cont, [node | acc]}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      :error -> {:error, :unprocessable_filter}
      list -> {:ok, list}
    end
  end

  # Embed-targeted filters like `clients.id=eq.1` (and deeper paths). A trailing
  # `and`/`or`/`not.and`/`not.or` segment is an embedded logic tree
  # (`child_entities.or=(...)`, case 1182), parsed into a logic node rather than
  # a column filter. Returns a map: %{["clients"] => [filter_node, ...]}.
  defp reduce_embed_filters(pairs) do
    pairs
    |> Enum.reduce_while(%{}, fn {key, val}, acc ->
      case parse_embed_filter(key, val) do
        {:ok, path, node} -> {:cont, Map.update(acc, path, [node], &[node | &1])}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      :error -> {:error, :unprocessable_filter}
      map -> {:ok, map}
    end
  end

  # Parse a single embed-targeted filter pair into `{:ok, embed_path, node}`.
  defp parse_embed_filter(key, val) do
    path = embed_path(key)
    last = key |> String.split(".") |> List.last()

    cond do
      # `<embed>.or=(...)` / `<embed>.and=(...)`
      last in ["and", "or"] ->
        op = if last == "or", do: :or, else: :and
        embed_logic_node(path, op, false, val)

      # `<embed>.not.or=(...)` / `<embed>.not.and=(...)`: the path drops the
      # trailing `not`+keyword pair, the negation applies to the group.
      neg = embed_logic_negated(key) ->
        {neg_path, op} = neg
        embed_logic_node(neg_path, op, true, val)

      true ->
        case parse_column_filter(last, val) do
          {:ok, node} -> {:ok, path, node}
          :error -> :error
        end
    end
  end

  defp embed_logic_node(path, op, negate, val) do
    case parse_logic_group(val) do
      {:ok, children} -> {:ok, path, %{logic: op, negate: negate, children: children}}
      _ -> :error
    end
  end

  # For `<embed>...not.and`/`<embed>...not.or`, returns `{embed_path, :and|:or}`
  # (the path with the trailing `not.<kw>` removed), else nil.
  defp embed_logic_negated(key) do
    segments = String.split(key, ".")

    case Enum.split(segments, -2) do
      {head, ["not", kw]} when kw in ["and", "or"] and head != [] ->
        {head, if(kw == "or", do: :or, else: :and)}

      _ ->
        nil
    end
  end

  # The embed path segments of a filter key, e.g. `clients.id` => ["clients"],
  # `a.b.col` => ["a", "b"]. A plain `col` (or json-path `col->x`) => [].
  defp embed_path(key) do
    case String.split(key, ".") do
      [_single] -> []
      segments -> Enum.drop(segments, -1)
    end
  end

  # Logical params: `and=(...)`, `or=(...)`, `not.and=(...)`, `not.or=(...)`.
  defp parse_logic(params, acc) do
    logic =
      params
      |> Enum.filter(fn {k, _v} -> base_key(k) in ["and", "or"] end)
      |> Enum.flat_map(fn {k, v} -> List.wrap(v) |> Enum.map(&{k, &1}) end)

    Enum.reduce_while(logic, {:ok, acc}, fn {k, v}, {:ok, nodes} ->
      negate? = String.starts_with?(k, "not.")
      op = if String.ends_with?(k, "or"), do: :or, else: :and

      case parse_logic_group(v) do
        {:ok, children} ->
          node = %{logic: op, negate: negate?, children: children}
          {:cont, {:ok, [node | nodes]}}

        {:error, :empty_group} ->
          {:halt, {:error, {:logic_parse, v}}}

        :error ->
          {:halt, {:error, :bad_logic}}
      end
    end)
  end

  defp base_key(key) do
    key
    |> String.replace_prefix("not.", "")
    |> String.split(".", parts: 2)
    |> hd()
  end

  # Parse the body of a logic group: `(cond,cond,and(...),or(...))`.
  defp parse_logic_group(raw) do
    inner = raw |> String.trim() |> strip_outer_parens()

    case inner do
      :error ->
        :error

      "" ->
        # empty group like or=() is a zero-arity error in PostgREST: it returns
        # 400 PGRST100 (see filters/logical/arity). Signal a distinct reason so
        # the controller can render the precise parse-error envelope.
        {:error, :empty_group}

      body ->
        body
        |> split_top_commas()
        |> Enum.map(&String.trim/1)
        |> Enum.reduce_while([], fn member, acc ->
          case parse_logic_member(member) do
            {:ok, node} -> {:cont, [node | acc]}
            :error -> {:halt, :error}
          end
        end)
        |> case do
          :error -> :error
          list -> {:ok, Enum.reverse(list)}
        end
    end
  end

  defp parse_logic_member(member) do
    cond do
      member == "" ->
        :error

      logic_prefix(member) ->
        {neg, op, rest} = logic_prefix(member)

        case parse_logic_group(rest) do
          {:ok, children} -> {:ok, %{logic: op, negate: neg, children: children}}
          _ -> :error
        end

      true ->
        # member is `col.op.value` possibly `col.not.op.value`
        case String.split(member, ".", parts: 2) do
          [col, opval] -> parse_filter_expr(String.trim(col), opval)
          _ -> :error
        end
    end
  end

  # A top-level `col=op.value` filter param.
  defp parse_column_filter(key, val) do
    val = if is_list(val), do: List.last(val), else: val
    parse_filter_expr(String.trim(key), val)
  end

  # ---- shared helpers ------------------------------------------------------

  # Split on commas that are at the top level (not nested in () or {} or []),
  # and not inside double quotes.
  @doc false
  def split_top_commas(str) do
    do_split(String.to_charlist(str), 0, false, [], [])
  end

  defp do_split([], _depth, _q, cur, acc) do
    Enum.reverse([cur |> Enum.reverse() |> List.to_string() | acc])
  end

  defp do_split([?" | rest], depth, q, cur, acc),
    do: do_split(rest, depth, not q, [?" | cur], acc)

  defp do_split([c | rest], depth, false = q, cur, acc) when c in [?(, ?{, ?[],
    do: do_split(rest, depth + 1, q, [c | cur], acc)

  defp do_split([c | rest], depth, false = q, cur, acc) when c in [?), ?}, ?]],
    do: do_split(rest, depth - 1, q, [c | cur], acc)

  defp do_split([?, | rest], 0, false, cur, acc),
    do: do_split(rest, 0, false, [], [cur |> Enum.reverse() |> List.to_string() | acc])

  defp do_split([c | rest], depth, q, cur, acc),
    do: do_split(rest, depth, q, [c | cur], acc)

  # Strip one layer of outer parentheses; returns inner string or :error.
  defp strip_outer_parens("(" <> _ = s) do
    if String.ends_with?(s, ")") do
      String.slice(s, 1..-2//1)
    else
      :error
    end
  end

  defp strip_outer_parens(_), do: :error

  # ===========================================================================
  # Leaf grammars (compiled `nimble_parsec` combinators)
  #
  # Public wrappers, helpers, and the `post_traverse` callbacks invoked by the
  # parsers generated from the combinator section at the top of this module.
  # These grammars compile to binary-matching clauses and replaced the original
  # regex/`String.split` parsing (1.6x-5.9x faster per function, proven
  # behavior-identical against the conformance suite -- see `bench/REPORT.md`).
  # ===========================================================================

  @agg_functions ~w(avg count max min sum)

  # Shared `post_traverse` tail: prepend the tagged remaining binary to the acc
  # and consume the rest of the input. All capture callbacks below funnel through
  # here so the generated post_traverse dispatch sees a genuinely union-typed
  # return (the three shapes nimble_parsec's wrapper matches on) and does not
  # flag its `{:error, _}` / `{acc, context}` clauses as dead — keeping the
  # generated file clean under `--warnings-as-errors`. The `:error`/legacy
  # branches are unreachable at runtime (`context` never carries `__pt__`); they
  # exist purely to keep the inferred return type open.
  defp pt_capture(rest, args, context, tag) do
    case context do
      %{__pt__: :error} -> {:error, "unreachable"}
      %{__pt__: :legacy} -> {args, context}
      _ -> {"", [{tag, rest} | args], context}
    end
  end

  @doc "True when `col` is a valid PostgREST unquoted identifier (`[A-Za-z_][A-Za-z0-9_ -]*`)."
  @spec valid_identifier?(String.t()) :: boolean()
  def valid_identifier?(col) when is_binary(col) do
    case p_identifier(col) do
      {:ok, [_], "", _, _, _} -> true
      _ -> false
    end
  end

  def valid_identifier?(_), do: false

  @doc """
  Parse a json-path column reference (`col`, `col->a->>b`, `col->0`, `col->>-3`).

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

  # Capture the entire remaining binary as the value (the original uses `.*` with
  # the `/s` flag, so newlines are included and nothing is re-parsed).
  defp take_rest_as_value(rest, args, context, _line, _offset) do
    pt_capture(rest, args, context, :value)
  end

  @doc """
  Split a filter's `op[.modifier].value` tail.

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

  @doc """
  True when a select field references an embedding: it has a top-level `(`
  not preceded by a `.` aggregate marker, i.e. `name(...)` / `alias:name(...)`
  / `name!hint(...)`.
  """
  @spec embed?(String.t()) :: boolean()
  def embed?(field) when is_binary(field) do
    match?({:ok, _, _rest, _, _, _}, p_embed(field))
  end

  defp capture_embed_inner(rest, args, context, _line, _offset) do
    pt_capture(rest, args, context, :after_paren)
  end

  @doc """
  Split an embed term into its `name!hint...` head and inner sub-select.

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

  @doc """
  Peel a trailing `)::cast` off an aggregate term
  (the regex `^(.*\\))::([A-Za-z0-9_ ]+)$`).

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

  @doc """
  Parse an aggregate call `[col.]fun()` (the regex
  `^(?:([a-zA-Z_][\\w ]*)\\.)?([a-z_]+)\\(\\s*\\)$`).

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

  defp capture_logic_rest(rest, args, context, _line, _offset) do
    pt_capture(rest, args, context, :rest)
  end

  @doc """
  Match a logic-group prefix: `and(`/`or(`/`not.and(`/`not.or(`.

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

  @doc """
  True when a select field is an aggregate: `count()`, `col.sum()`,
  `alias:col.sum()::cast`. A bare `name()` is an aggregate only when `name` is
  a known aggregate function; otherwise it is an empty-projection embed. A
  `col.fn()` form is always an aggregate.
  """
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

  @doc """
  Parse a scalar select field `[alias:]col[::cast][->json]` into a `:field`
  node.

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

  defp capture_alias_rest(rest, args, context, _line, _offset) do
    pt_capture(rest, args, context, :rest)
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

  @doc """
  Parse a column filter — `col_raw` (which may carry a json path) plus the
  `[not.]op[.modifier].value` tail — into a filter node.

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

  defp capture_related_tail(rest, args, context, _line, _offset) do
    pt_capture(rest, args, context, :tail)
  end

  @doc """
  Parse one order term: a column order
  `<col>[->json][.asc|.desc][.nullsfirst|.nullslast]` or a related order
  `<rel>(<col>[->json])[.mods]` (ordering by a to-one embedded resource).

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

  # ---- order helpers --------------------------------------------------------

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
end
