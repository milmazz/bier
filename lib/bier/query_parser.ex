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

  column_cast =
    cast_separator
    |> ignore()
    |> concat(casting_types)
    |> unwrap_and_tag(:cast)

  column =
    column_alias
    |> optional()
    |> concat(tag(identifier, :column))
    |> optional(column_cast)

  detailed_select =
    column
    |> optional(ignore(optional(column_separator, whitespace)))
    |> post_traverse(:join_and_wrap)
    |> times(min: 1)
    |> eos()

  defp join_and_wrap(_rest, args, context, _line, _offset) do
    # TODO: Probably is a good idea to pass the column, cast, and column alias
    # as a data structure instead of a string, that way, a following step could
    # verify if the given column actually exist in the given table, but first, we need
    # to introspect this information from the DB.
    column = Keyword.fetch!(args, :column)
    cast = Keyword.get(args, :cast)
    column_alias = Keyword.get(args, :alias)

    result =
      cond do
        cast && column_alias ->
          ~s|#{column}::#{cast} AS "#{column_alias}"|

        cast ->
          "#{column}::#{cast}"

        column_alias ->
          ~s|#{column} AS "#{column_alias}"|

        true ->
          to_string(column)
      end

    {List.wrap(result), context}
  end

  defparsecp(:select, choice([default_select, detailed_select]))

  @doc """
  Parse the given `select` query string

  ## Examples

      iex> parse_select("*")
      {:ok, "*"}
      iex> parse_select("first_name,age")
      {:ok, "first_name, age"}
      iex> parse_select("fullName:full_name,birthDate:birth_date")
      {:ok, ~S/full_name AS "fullName", birth_date AS "birthDate"/}
      iex> parse_select("uno:first::text, dos:second, third, forth::text")
      {:ok, ~S/first::text AS "uno", second AS "dos", third, forth::text/}
  """
  @spec parse_select(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def parse_select(select) do
    case select(select) do
      {:ok, result, _rest = "", _context, _line, _byte_offset} ->
        {:ok, transform_select(result)}

      {:error, reason, _rest, _contact, _line, _byte_offset} ->
        {:error, reason}
    end
  end

  defp transform_select(result) when is_list(result) do
    case Keyword.get(result, :default) do
      nil ->
        Enum.join(result, ", ")

      '*' ->
        "*"
    end
  end

  ########################
  ## Horizontal Filters ##
  ########################
  filter_separator = ascii_char([?.])

  filter_types =
    [
      string("eq") |> replace("="),
      string("gte") |> replace(">="),
      string("gt") |> replace(">"),
      string("lte") |> replace("<="),
      string("lt") |> replace("<"),
      string("neq") |> replace("<>"),
      string("ilike"),
      string("like"),
      string("in"),
      string("is")
    ]
    |> choice()
    |> tag(:operator)

  horizontal_filter =
    string("not")
    |> tag(:negation)
    |> ignore(filter_separator)
    |> optional()
    |> concat(filter_types)
    |> ignore(filter_separator)

  defparsec(:horizontal_filter, horizontal_filter)

  @doc """
  Parse the given horizontal filters (rows)

  You can filter result rows by filtering conditions on columns.

  ## Examples

      iex> parse_filters(%{age: "lt.13"})
      {:ok, [{:age, %{operator: "<", value: "13", negation?: false}}]}
      iex> parse_filters(%{age: "gt.13"})
      {:ok, [{:age, %{operator: ">", value: "13", negation?: false}}]}
      iex> parse_filters(%{age: "gte.13"})
      {:ok, [{:age, %{operator: ">=", value: "13", negation?: false}}]}
      iex> parse_filters(%{age: "not.gte.13"})
      {:ok, [{:age, %{operator: ">=", value: "13", negation?: true}}]}
  """
  def parse_filters(params) when is_map(params) do
    result =
      Enum.reduce_while(params, [], fn {field, filter}, acc ->
        with {:ok, parsed, rest, %{}, _, _} <- horizontal_filter(filter),
             operator = parsed |> Keyword.get(:operator) |> hd(),
             {operator, value} <- operator(operator, rest) do
          parsed_filter = %{
            operator: operator,
            value: value,
            negation?: Keyword.has_key?(parsed, :negation)
          }

          {:cont, [{field, parsed_filter} | acc]}
        else
          _ ->
            {:halt, :bad_request}
        end
      end)

    case result do
      :bad_request -> {:error, :bad_request}
      result -> {:ok, result}
    end
  end

  defp operator("like", value), do: {"LIKE", String.replace(value, "*", "%")}
  defp operator("ilike", value), do: {"ILIKE", String.replace(value, "*", "%")}

  defp operator("is", value) when value in ["true", "false"],
    do: {"IS", String.to_existing_atom(value)}

  defp operator("is", _value), do: :error

  defp operator(operator, value), do: {operator, value}

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
end
