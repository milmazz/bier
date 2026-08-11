defmodule Bier.Render do
  @moduledoc """
  Renders a JSON-array result body (the text produced by `Bier.QueryExecutor`)
  into the negotiated output format: CSV, a singular object, a nulls-stripped
  array/object, or plain JSON.

  The bodies themselves are built by PostgreSQL, never re-encoded here: a
  decode/encode round trip loses JSON object key order (Elixir maps are
  unordered) and the exact numeric text PostgreSQL emitted (`45.512230` becomes
  `45.51223`) — issue #109. So null-stripping happens in the aggregate
  (`Bier.QueryExecutor`'s `json_strip_nulls`, upstream's `addNullsToSnip`), and
  the singular form is the array's single element sliced out of the text
  PostgreSQL already produced — byte-identical to upstream's
  `json_agg(_postgrest_t)->0`. Only CSV, which is a different serialization
  entirely, decodes; it also needs an explicit ordered column list (it cannot
  rely on JSON object key order).
  """

  alias Bier.MediaType

  @doc """
  Transform the executor's JSON-array `body` for the resolved media type.

  Returns `{:ok, output_string}` or `{:error, reason}` (e.g. a singular
  plurality violation).

    * `:columns` — ordered column names used for CSV output.

  The transform is timed as the `response` phase of `Server-Timing`
  (`Bier.ServerTiming`); it runs before the caller calls `send_resp`, so the
  duration is recorded in time for the header.
  """
  def render(media, body, opts) do
    Bier.ServerTiming.measure(:response, fn -> do_render(media, body, opts) end)
  end

  # Singular: the plurality check needs the element count, but the body must be
  # the text PostgreSQL produced, so the decode is used only to count and the
  # element is sliced out of the original bytes. Any `nulls=stripped` on this
  # media type was already applied by the aggregate.
  defp do_render(%MediaType{symbol: :singular}, body, _opts) do
    case decode(body) do
      [_row] -> {:ok, single_element(body)}
      other -> {:error, {:not_singular, length(other)}}
    end
  end

  # `nulls=stripped` array: `json_strip_nulls` already ran in the aggregate.
  defp do_render(%MediaType{symbol: :array_strip}, body, _opts), do: {:ok, body}

  defp do_render(%MediaType{symbol: :csv}, body, opts) do
    rows = decode(body)
    columns = csv_columns(rows, Keyword.get(opts, :columns))
    {:ok, to_csv(rows, columns)}
  end

  # json / openapi / plan / other: pass through unchanged.
  defp do_render(_mt, body, _opts), do: {:ok, body}

  # ---- helpers -------------------------------------------------------------

  # The single element of a one-element JSON array, taken verbatim from the
  # aggregate's own text. `json_agg` renders a one-row aggregate as `[<elem>]`
  # with no padding, so dropping the brackets yields exactly what
  # `json_agg(_postgrest_t)->0` would have. The caller has already established
  # that the array holds exactly one element; the fallback re-encodes rather
  # than crashing if the body ever arrives in another shape.
  defp single_element(<<"[", rest::binary>> = body) when byte_size(rest) > 0 do
    inner_size = byte_size(rest) - 1

    case rest do
      <<inner::binary-size(^inner_size), "]">> -> inner
      _ -> body
    end
  end

  defp single_element(body), do: body

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
