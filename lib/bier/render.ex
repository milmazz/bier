defmodule Bier.Render do
  @moduledoc """
  Renders a JSON-array result body (the text produced by `Bier.QueryExecutor`)
  into the negotiated output format: CSV, a singular object, a nulls-stripped
  array/object, or plain JSON.

  Singular and nulls-stripped transforms operate on the decoded rows; CSV needs
  an explicit ordered column list (it cannot rely on JSON object key order).
  """

  alias Bier.MediaType

  @doc """
  Transform the executor's JSON-array `body` for the resolved media type.

  Returns `{:ok, output_string}` or `{:error, reason}` (e.g. a singular
  plurality violation).

    * `:columns` — ordered column names used for CSV output.
  """
  def render(%MediaType{symbol: :singular} = mt, body, _opts) do
    rows = decode(body)

    case rows do
      [row] -> {:ok, encode(maybe_strip(row, mt))}
      other -> {:error, {:not_singular, length(other)}}
    end
  end

  def render(%MediaType{symbol: :array_strip}, body, _opts) do
    rows = decode(body)
    {:ok, encode(Enum.map(rows, &strip_nulls/1))}
  end

  def render(%MediaType{symbol: :csv}, body, opts) do
    rows = decode(body)
    columns = csv_columns(rows, Keyword.get(opts, :columns))
    {:ok, to_csv(rows, columns)}
  end

  # json / openapi / plan / other: pass through unchanged.
  def render(_mt, body, _opts), do: {:ok, body}

  # ---- helpers -------------------------------------------------------------

  defp maybe_strip(row, %MediaType{params: %{strip: true}}), do: strip_nulls(row)
  defp maybe_strip(row, _mt), do: row

  defp strip_nulls(row) when is_map(row) do
    row
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp strip_nulls(other), do: other

  defp decode("[]"), do: []
  defp decode("null"), do: []
  defp decode(body), do: Bier.json_library().decode!(body)

  defp encode(term), do: Bier.json_library().encode!(term)

  # Determine CSV column order: use the explicit list when given, otherwise the
  # union of keys across rows in first-seen order.
  defp csv_columns(_rows, columns) when is_list(columns) and columns != [], do: columns

  defp csv_columns(rows, _) do
    Enum.reduce(rows, [], fn row, acc ->
      keys = if is_map(row), do: Map.keys(row), else: []
      acc ++ Enum.reject(keys, &(&1 in acc))
    end)
  end

  # CSV: a header row of column names, then one row per record. A null cell is
  # rendered empty. Values are RFC-4180 quoted only when needed.
  defp to_csv(rows, columns) do
    header = Enum.map_join(columns, ",", &csv_field/1)

    data =
      Enum.map_join(rows, "\n", fn row ->
        Enum.map_join(columns, ",", fn col -> csv_cell(Map.get(row, col)) end)
      end)

    case data do
      "" -> header
      _ -> header <> "\n" <> data
    end
  end

  defp csv_cell(nil), do: ""
  defp csv_cell(v) when is_binary(v), do: csv_field(v)
  defp csv_cell(v) when is_boolean(v), do: to_string(v)
  defp csv_cell(v) when is_number(v), do: to_string(v)
  defp csv_cell(v), do: csv_field(encode(v))

  defp csv_field(value) do
    str = to_string(value)

    if String.contains?(str, [",", "\"", "\n", "\r"]) do
      "\"" <> String.replace(str, "\"", "\"\"") <> "\""
    else
      str
    end
  end
end
