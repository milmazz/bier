defmodule Bier.QueryParser do
  @moduledoc """
  Parser for SQL queries given via query strings
  """
  import NimbleParsec

  @space 0x0020
  @horizontal_tab 0x0009

  # SQL identifiers and key words must begin with a letter (a-z, but also
  # letters with diacritical marks and non-Latin letters) or an underscore (_).
  # Subsequent characters in an identifier or key word can be letters,
  # underscores, digits (0-9), or dollar signs ($). Note that dollar signs are
  # not allowed in identifiers according to the letter of the SQL standard, so
  # their use might render applications less portable. The SQL standard will
  # not define a key word that contains digits or starts or ends with an
  # underscore, so identifiers of this form are safe against possible conflict
  # with future extensions of the standard.
  #
  # See: https://www.postgresql.org/docs/9.2/sql-syntax-lexical.html#SQL-SYNTAX-IDENTIFIERS
  # FIXME: Complete this based on previous description
  identifier =
    [?_, ?A..?Z, ?a..?z]
    |> ascii_char()
    |> repeat(ascii_char([?_, ?a..?z, ?A..?Z, ?0..?9]))

  whitespace =
    ascii_char([
      @horizontal_tab,
      @space
    ])

  default_select =
    ascii_char([?*])
    |> concat(eos())
    |> tag(:default)

  column_separator = ascii_char([?,])
  alias_separator = ascii_char([?:])
  cast_separator = times(ascii_char([?:]), 2)

  column_alias =
    identifier
    |> lookahead_not(cast_separator)
    |> concat(ignore(alias_separator))
    |> tag(:alias)

  # TODO: Complete the following list
  casting_types =
    choice([
      string("boolean"),
      string("date"),
      string("float"),
      string("integer"),
      string("interval"),
      string("text"),
      string("timestamp")
    ])

  defp normalize(rest, [casting_type], %{} = context, {_line, _line_offset}, _byte_offset) do
    {rest, casting_type |> String.reverse() |> String.to_charlist(), context}
  end

  column_cast =
    cast_separator
    |> ignore()
    |> concat(casting_types)
    |> post_traverse(:normalize)
    |> tag(:cast)

  column =
    column_alias
    |> optional()
    |> concat(tag(identifier, :name))
    |> optional(column_cast)
    |> wrap()

  detailed_select =
    column
    |> optional(ignore(optional(column_separator, whitespace)))
    |> times(min: 1)
    |> eos()

  defparsecp(:select, choice([default_select, detailed_select]))

  @doc """
  Parse the given `select` query string

  ## Examples

      iex> parse_select("*")
      {:ok, [default: ~c"*"]}
      iex> parse_select("first_name,age")
      {:ok, [[name: ~c"first_name"], [name: ~c"age"]]}
      iex> parse_select("fullName:full_name,birthDate:birth_date")
      {:ok, [[alias: ~c"fullName", name: ~c"full_name"], [alias: ~c"birthDate", name: ~c"birth_date"]]}
      iex> parse_select("uno:first::text, dos:second, third, forth::text")
      {:ok, [[alias: ~c"uno", name: ~c"first", cast: ~c"text"], [alias: ~c"dos", name: ~c"second"], [name: ~c"third"], [name: ~c"forth", cast: ~c"text"]]}
  """
  @spec parse_select(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def parse_select(select) do
    case select(select) do
      {:ok, result, _rest = "", _context, _line, _byte_offset} ->
        {:ok, result}

      {:error, reason, _rest, _contact, _line, _byte_offset} ->
        {:error, reason}
    end
  end

  ########################
  ## Horizontal Filters ##
  ########################
  filter_separator = ascii_char([?.])

  # TODO: Extract the following into a common combinator
  # |> post_traverse(:normalize)
  # |> tag(:operator)
  # |> ignore(filter_separator)

  is_value =
    [
      string("false") |> replace(false),
      string("true") |> replace(true)
    ]
    |> choice()
    |> unwrap_and_tag(:value)

  is_operator =
    string("is")
    |> post_traverse(:normalize)
    |> tag(:operator)
    |> ignore(filter_separator)
    |> concat(is_value)

  like_value =
    [
      ascii_char([?*]) |> replace(?%),
      ascii_char([])
    ]
    |> choice()
    |> repeat()
    |> eos()
    |> tag(:value)

  like_operator =
    [
      string("like"),
      string("ilike")
    ]
    |> choice()
    |> post_traverse(:normalize)
    |> tag(:operator)
    |> ignore(filter_separator)
    |> concat(like_value)

  rest_value =
    ascii_char([])
    |> repeat()
    |> eos()
    |> tag(:value)

  rest_operator =
    [
      string("eq") |> replace("="),
      string("gte") |> replace(">="),
      string("gt") |> replace(">"),
      string("lte") |> replace("<="),
      string("lt") |> replace("<"),
      string("neq") |> replace("<>"),
      string("in")
    ]
    |> choice()
    |> post_traverse(:normalize)
    |> tag(:operator)
    |> ignore(filter_separator)
    |> concat(rest_value)

  horizontal_filter =
    string("not")
    |> replace(true)
    |> unwrap_and_tag(:negation?)
    |> ignore(filter_separator)
    |> optional()
    |> choice([is_operator, like_operator, rest_operator])

  defparsecp(:horizontal_filter, horizontal_filter)

  @doc """
  Parse the given horizontal filters (rows)

  You can filter result rows by filtering conditions on columns.

  ## Examples

      iex> parse_filters(%{age: "lt.13"})
      {:ok, [{:age, [negation?: false, operator: ~c"<", value: ~c"13"]}]}
      iex> parse_filters(%{age: "gt.13"})
      {:ok, [{:age, [negation?: false, operator: ~c">", value: ~c"13"]}]}
      iex> parse_filters(%{age: "gte.13"})
      {:ok, [{:age, [negation?: false, operator: ~c">=", value: ~c"13"]}]}
      iex> parse_filters(%{age: "not.gte.13"})
      {:ok, [{:age, [negation?: true, operator: ~c">=", value: ~c"13"]}]}
  """
  def parse_filters(params) when is_map(params) do
    result =
      Enum.reduce_while(params, [], fn {field, filter}, acc ->
        case horizontal_filter(filter) do
          {:ok, parsed, "", %{}, _, _} ->
            parsed_filter = Keyword.put_new(parsed, :negation?, false)
            {:cont, [{field, parsed_filter} | acc]}

          _ ->
            {:halt, :bad_request}
        end
      end)

    case result do
      :bad_request -> {:error, :bad_request}
      result -> {:ok, result}
    end
  end

  defguardp order_direction(direction) when direction in ["asc", "desc"]
  defguardp nulls_order(nulls) when nulls in ["nullsfirst", "nullslast"]

  @doc """
  Parses the given order clause

  ## Examples

      iex> parse_order("")
      {:ok, []}
      iex> parse_order("age")
      {:ok, [{"age", "asc", "nulls last"}]}
      iex> parse_order("age.desc,height.asc")
      {:ok, [{"height", "asc", "nulls last"}, {"age", "desc", "nulls first"}]}
      iex> parse_order("age.nullsfirst")
      {:ok, [{"age", "asc", "nulls first"}]}
      iex> parse_order("age.desc.nullslast")
      {:ok, [{"age", "desc", "nulls last"}]}
      iex> parse_order("age.left,height.asc")
      {:error, :bad_request}
  """
  def parse_order(""), do: {:ok, []}

  def parse_order(order) do
    result =
      order
      |> String.split(",")
      |> Enum.reduce_while([], fn line, acc ->
        case String.split(line, ".", parts: 3) do
          [field, direction, nulls] when order_direction(direction) and nulls_order(nulls) ->
            {:cont, [{field, direction, transform_nulls(nulls)} | acc]}

          [field, direction] when order_direction(direction) ->
            {:cont, [{field, direction, default_null_option(direction)} | acc]}

          [field, nulls] when nulls_order(nulls) ->
            {:cont, [{field, "asc", transform_nulls(nulls)} | acc]}

          [field] ->
            {:cont, [{field, "asc", "nulls last"} | acc]}

          _ ->
            {:halt, :bad_request}
        end
      end)

    case result do
      :bad_request -> {:error, :bad_request}
      result -> {:ok, result}
    end
  end

  defp default_null_option("desc"), do: "nulls first"
  defp default_null_option("asc"), do: "nulls last"

  defp transform_nulls("nullsfirst"), do: "nulls first"
  defp transform_nulls("nullslast"), do: "nulls last"

  @doc """
  Parse the given limit

  ## Examples

      iex> parse_limit(10)
      {:ok, 10}
      iex> parse_limit("10")
      {:ok, 10}
      iex> parse_limit("10.1")
      {:error, :bad_request}
      iex> parse_limit("0")
      {:error, :bad_request}
      iex> parse_limit(%{})
      {:error, :bad_request}
  """
  def parse_limit(limit) when is_integer(limit) and limit > 0, do: {:ok, limit}

  def parse_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {limit, ""} when limit > 0 -> {:ok, limit}
      _ -> {:error, :bad_request}
    end
  end

  def parse_limit(_), do: {:error, :bad_request}

  @doc """
  Parses request body before querying the database
  """
  def parse_request_body(params) when is_list(params) or is_map(params) do
    params
    |> List.wrap()
    |> prepare_params_for_insert()
  end

  defp prepare_params_for_insert([h | _t] = params) do
    keys = Map.keys(h)

    result =
      Enum.reduce_while(params, [], fn p, acc ->
        case prepare_row_for_insert(keys, p) do
          {values, map} when map_size(map) == 0 ->
            {:cont, [Enum.reverse(values) | acc]}

          _ ->
            {:halt, :mismatch}
        end
      end)

    case result do
      :mismatch ->
        {:error, :mismatch}

      values ->
        {:ok, %{keys: keys, values: values}}
    end
  end

  defp prepare_row_for_insert(keys, row) do
    Enum.reduce_while(keys, {[], row}, fn key, {values, map} ->
      case Map.pop(map, key) do
        {nil, _} ->
          {:halt, :mismatch}

        {v, updated_map} ->
          {:cont, {[prepare_value_for_insert(v) | values], updated_map}}
      end
    end)
  end

  defp prepare_value_for_insert(value) when is_binary(value), do: "'#{value}'"
  defp prepare_value_for_insert(value), do: value

  # ==========================================================================
  # Request pipeline parsing (PostgREST-shaped)
  #
  # The functions below are a separate, structured parsing path used by the
  # request pipeline (`Bier.QueryExecutor`). They are independent from the
  # legacy `parse_select/1`, `parse_filters/1`, `parse_order/1` helpers above
  # (kept for backwards compatibility and their doctests). They take the raw
  # query string of a request and produce an AST of selects/filters/order that
  # `Bier.QueryExecutor` turns into one parameterized SQL statement.
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
    case Regex.run(~r/->>?(-)(-)/, sel, return: :index) do
      [_, _first_dash, {pos, _}] ->
        {"unexpected \"-\" expecting digit", pos + 1}

      _ ->
        # Fallback: point just past the last valid prefix.
        {"unexpected end of input", String.length(sel) + 1}
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

  # A field references an embedding when it has a `(` at the top level that is
  # not preceded by a `.` aggregate marker, i.e. `name(...)` / `alias:name(...)`
  # / `name!hint(...)`.
  defp embed?(field) do
    Regex.match?(~r/^(?:[a-zA-Z_][\w ]*:)?[a-zA-Z_][\w ]*(?:![\w ]+)*\(/u, field)
  end

  @agg_functions ~w(avg count max min sum)

  # Aggregate forms: `count()`, `col.sum()`, `alias:col.sum()::cast`.
  #
  # A bare `name()` (no `col.` prefix) is only an aggregate when `name` is one of
  # the known aggregate functions; otherwise `name()` is an empty-projection
  # embed (e.g. `child_entities()` used for null filtering). A `col.fn()` form is
  # always an aggregate.
  defp aggregate?(field) do
    case Regex.run(
           ~r/^(?:[a-zA-Z_][\w ]*:)?(?:([a-zA-Z_][\w ]*)\.)?([a-z_]+)\(\s*\)(::[A-Za-z0-9_ ]+)?$/u,
           field
         ) do
      [_, "", fun | _] -> fun in @agg_functions
      [_, _col, _fun | _] -> true
      _ -> false
    end
  end

  defp parse_aggregate(field) do
    {out_alias, rest} = split_alias(field)

    {cast, rest} =
      case Regex.run(~r/^(.*\))::([A-Za-z0-9_ ]+)$/, rest) do
        [_, r, c] -> {String.trim(c), r}
        _ -> {nil, rest}
      end

    case Regex.run(~r/^(?:([a-zA-Z_][\w ]*)\.)?([a-z_]+)\(\s*\)$/u, rest) do
      [_, "", fun] ->
        {:ok, %{kind: :agg, column: nil, fun: fun, alias: out_alias, cast: cast}}

      [_, col, fun] ->
        if valid_identifier?(col),
          do: {:ok, %{kind: :agg, column: col, fun: fun, alias: out_alias, cast: cast}},
          else: {:error, {:select_parse, field}}

      _ ->
        {:error, {:select_parse, field}}
    end
  end

  # Parse an embedding term: `[alias:]relation[!hint...][!inner|!left](sub-select)`
  defp parse_embed(field, spread?) do
    {emb_alias, rest} = split_alias(field)

    case Regex.run(~r/^([a-zA-Z_][\w ]*(?:![\w ]+)*)\((.*)\)$/su, rest) do
      [_, head, inner] ->
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

  # Split a leading `alias:` (not a `::` cast) off the front of a term.
  defp split_alias(field) do
    case Regex.run(~r/^([a-zA-Z_][\w ]*?):(?!:)(.+)$/, field) do
      [_, a, r] -> {String.trim(a), r}
      _ -> {nil, field}
    end
  end

  defp parse_scalar_select(field) do
    {col_alias, rest} = split_alias(field)

    {cast, rest} =
      case String.split(rest, "::", parts: 2) do
        [r, c] -> {String.trim(c), String.trim(r)}
        [r] -> {nil, String.trim(r)}
      end

    with {:ok, {col, json_path}} <- parse_json_path(rest) do
      if valid_identifier?(col) do
        {:ok, %{kind: :field, column: col, alias: col_alias, cast: cast, json_path: json_path}}
      else
        {:error, {:select_parse, field}}
      end
    else
      _ -> {:error, {:select_parse, field}}
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

  # Order term, one of:
  #
  #   * column order:  `<col>[->json][.asc|.desc][.nullsfirst|.nullslast]`
  #   * related order: `<rel>(<col>[->json])[.asc|.desc][.nulls...]` — orders by a
  #     column of a to-one related (embedded) resource.
  defp parse_order_term(term) do
    case Regex.run(~r/^([a-zA-Z_][\w ]*)\((.+)\)((?:\.[a-z]+)*)$/u, term) do
      [_, rel, inner, mods] ->
        parse_related_order_term(String.trim(rel), String.trim(inner), mods)

      _ ->
        parse_column_order_term(term)
    end
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

  # PostgREST renders a precise parser error for bad order syntax. We reproduce
  # the common case (an unexpected trailing token after a valid prefix) used by
  # the conformance suite; other malformed terms fall back to the same envelope.
  defp order_error(term) do
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
      |> Enum.reject(fn {k, _v} -> base_key(k) in @reserved end)
      |> Enum.reject(fn {k, _v} ->
        String.ends_with?(k, ".order") or String.ends_with?(k, ".limit") or
          String.ends_with?(k, ".offset")
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

        case parse_logic_group(val) do
          {:ok, children} -> {:ok, path, %{logic: op, negate: false, children: children}}
          _ -> :error
        end

      # `<embed>.not.or=(...)` / `<embed>.not.and=(...)`: the path drops the
      # trailing `not`+keyword pair, the negation applies to the group.
      neg = embed_logic_negated(key) ->
        {neg_path, op} = neg

        case parse_logic_group(val) do
          {:ok, children} -> {:ok, neg_path, %{logic: op, negate: true, children: children}}
          _ -> :error
        end

      true ->
        case parse_column_filter(last, val) do
          {:ok, node} -> {:ok, path, node}
          :error -> :error
        end
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

  # Returns {negate?, :and|:or, "(...)"} if member begins with and(/or(/not.and(.
  # Whitespace is permitted between the and/or keyword and its opening paren
  # (AndOrParamsSpec "allows whitespace", case 1169).
  defp logic_prefix(member) do
    cond do
      match = Regex.run(~r/^not\.and\s*(\(.*\))$/s, member) -> {true, :and, Enum.at(match, 1)}
      match = Regex.run(~r/^not\.or\s*(\(.*\))$/s, member) -> {true, :or, Enum.at(match, 1)}
      match = Regex.run(~r/^and\s*(\(.*\))$/s, member) -> {false, :and, Enum.at(match, 1)}
      match = Regex.run(~r/^or\s*(\(.*\))$/s, member) -> {false, :or, Enum.at(match, 1)}
      true -> nil
    end
  end

  # A top-level `col=op.value` filter param.
  defp parse_column_filter(key, val) do
    val = if is_list(val), do: List.last(val), else: val
    parse_filter_expr(String.trim(key), val)
  end

  # Parse `op.value` (with optional `not.` prefix, quantifier `op(any|all)`,
  # fts language `fts(lang)`) against column `col` (which may have a json path).
  defp parse_filter_expr(col_raw, opval) do
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

  # Splits `op.value`, handling `op(any)`/`op(all)` quantifiers and `fts(lang)`.
  defp split_op_value(opval) do
    case Regex.run(~r/^([a-z]+)(\(([a-z_]+)\))?\.(.*)$/s, opval) do
      [_, op, "", _, value] -> {:ok, op, nil, value}
      [_, op, _, modifier, value] -> {:ok, op, modifier, value}
      _ -> :error
    end
  end

  # ---- shared helpers ------------------------------------------------------

  # Parse a column reference that may carry a JSON path: `col`, `col->a->>b`,
  # `col->0`, `col->>-3`. Returns {:ok, {base_col, [{:arrow|:arrow_text, key}]}}.
  defp parse_json_path(str) do
    case String.split(str, ~r/->>?/, include_captures: true) do
      [col] ->
        {:ok, {col, []}}

      [col | rest] ->
        steps = Enum.chunk_every(rest, 2)

        path =
          Enum.reduce_while(steps, [], fn
            [arrow, key], acc ->
              kind = if arrow == "->>", do: :arrow_text, else: :arrow
              if json_key_valid?(key), do: {:cont, [{kind, key} | acc]}, else: {:halt, :error}

            _, _ ->
              {:halt, :error}
          end)

        case path do
          :error -> :error
          p -> {:ok, {col, Enum.reverse(p)}}
        end
    end
  end

  defp json_key_valid?(key) do
    key != "" and (Regex.match?(~r/^-?\d+$/, key) or Regex.match?(~r/^[\w ]+$/u, key))
  end

  defp valid_identifier?(col) do
    # PostgREST allows letters, digits, underscore, space and dash in unquoted
    # column references (e.g. `field-with_sep`).
    Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_ -]*$/u, col)
  end

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
end
