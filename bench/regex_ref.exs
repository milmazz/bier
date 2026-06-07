# Faithful copies of the private regex/string leaf-grammar implementations in
# `Bier.QueryParser` (the module's twins are private, so we mirror them here to
# benchmark and parity-check them directly against `Bier.QueryParser.Nimble`).
#
# These bodies are kept byte-for-byte equivalent to the `*_regex` clauses in
# lib/bier/query_parser.ex; if those change, update here too.
#
# Loaded via `Code.require_file("regex_ref.exs", __DIR__)`.

defmodule Bench.RegexRef do
  @moduledoc false
  alias Bier.QueryParser, as: QP

  def parse_json_path(str) do
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

  def split_op_value(opval) do
    case Regex.run(~r/^([a-z]+)(\(([a-z_]+)\))?\.(.*)$/s, opval) do
      [_, op, "", _, value] -> {:ok, op, nil, value}
      [_, op, _, modifier, value] -> {:ok, op, modifier, value}
      _ -> :error
    end
  end

  def valid_identifier?(col), do: Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_ -]*$/u, col)

  def embed?(field) do
    Regex.match?(~r/^(?:[a-zA-Z_][\w ]*:)?[a-zA-Z_][\w ]*(?:![\w ]+)*\(/u, field)
  end

  @agg_functions ~w(avg count max min sum)

  def aggregate?(field) do
    case Regex.run(
           ~r/^(?:[a-zA-Z_][\w ]*:)?(?:([a-zA-Z_][\w ]*)\.)?([a-z_]+)\(\s*\)(::[A-Za-z0-9_ ]+)?$/u,
           field
         ) do
      [_, "", fun | _] -> fun in @agg_functions
      [_, _col, _fun | _] -> true
      _ -> false
    end
  end

  def split_alias(field) do
    case Regex.run(~r/^([a-zA-Z_][\w ]*?):(?!:)(.+)$/, field) do
      [_, a, r] -> {String.trim(a), r}
      _ -> {nil, field}
    end
  end

  def parse_scalar_select(field) do
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

  def parse_filter_expr(col_raw, opval) do
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

  def parse_order_term(term) do
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
      _ -> QP.order_error(term)
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
      _ -> QP.order_error(rel <> "(" <> inner <> ")" <> mods)
    end
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
end
