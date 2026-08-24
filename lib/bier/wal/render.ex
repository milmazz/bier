defmodule Bier.Wal.Render do
  @moduledoc """
  Renders a decoded WAL event into the change feed's `data:` JSON.

  Value typing is a fixed OID map — no per-event database work: booleans,
  the integer family, and floats become JSON scalars; `json`/`jsonb` embed
  as parsed JSON; everything else (text, timestamps, uuid, arrays, and
  notably `numeric`, which stays precision-safe) passes through as the
  Postgres text representation in a JSON string. `NaN`/`Infinity` floats
  render as strings (JSON has no spelling for them). TOAST columns an
  UPDATE did not rewrite are omitted from `row` and listed in `unchanged`.
  """

  @bool_oid 16
  @int_oids [20, 21, 23]
  @float_oids [700, 701]
  @json_oids [114, 3802]

  @doc """
  The `data:` payload as a map; the caller JSON-encodes it. `allowed` is
  `:all` or the set of column names the subscriber's role may SELECT.
  """
  @spec data(map(), DateTime.t(), :all | MapSet.t()) :: map()
  def data(%{kind: :truncate, relation: rel}, commit_at, _allowed) do
    envelope("TRUNCATE", rel, commit_at)
  end

  def data(%{kind: kind, relation: rel} = event, commit_at, allowed) do
    types = Map.new(rel.columns, &{&1.name, &1.type_oid})
    {row, unchanged} = split_row(Map.get(event, :row), allowed, types)

    envelope(type_name(kind), rel, commit_at)
    |> Map.put("row", row)
    |> Map.put("unchanged", unchanged)
    |> put_old(event, allowed, types)
    |> drop_nil_sections(kind)
  end

  defp envelope(type, rel, commit_at) do
    %{
      "type" => type,
      "schema" => rel.schema,
      "table" => rel.table,
      "commit_at" => DateTime.to_iso8601(commit_at)
    }
  end

  defp type_name(:insert), do: "INSERT"
  defp type_name(:update), do: "UPDATE"
  defp type_name(:delete), do: "DELETE"

  # DELETE has old but no row; UPDATE without a logged old image has row but
  # no old. Drop whichever section this event legitimately lacks.
  defp drop_nil_sections(data, :delete), do: Map.drop(data, ["row", "unchanged"])
  defp drop_nil_sections(data, _kind), do: data

  defp put_old(data, %{old: old, old_kind: old_kind}, allowed, types) when is_map(old) do
    {filtered, _unchanged} = split_row(old, allowed, types)

    data
    |> Map.put("old", filtered)
    |> Map.put("old_kind", Atom.to_string(old_kind))
  end

  defp put_old(data, _event, _allowed, _types), do: data

  defp split_row(nil, _allowed, _types), do: {nil, []}

  defp split_row(row, allowed, types) do
    visible = Enum.filter(row, fn {name, _v} -> allowed == :all or name in allowed end)
    {unchanged, present} = Enum.split_with(visible, fn {_n, v} -> v == :unchanged_toast end)

    {Map.new(present, fn {name, value} -> {name, convert(value, Map.get(types, name))} end),
     unchanged |> Enum.map(&elem(&1, 0)) |> Enum.sort()}
  end

  defp convert(nil, _oid), do: nil
  defp convert("t", @bool_oid), do: true
  defp convert("f", @bool_oid), do: false
  defp convert(text, oid) when oid in @int_oids, do: String.to_integer(text)

  defp convert(text, oid) when oid in @float_oids do
    case Float.parse(text) do
      {float, ""} -> float
      # NaN, Infinity, -Infinity have no JSON number spelling.
      _ -> text
    end
  end

  defp convert(text, oid) when oid in @json_oids do
    case Bier.json_library().decode(text) do
      {:ok, value} -> value
      _ -> text
    end
  end

  defp convert(text, _oid), do: text
end
