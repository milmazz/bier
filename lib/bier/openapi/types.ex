defmodule Bier.OpenAPI.Types do
  @moduledoc """
  PostgreSQL type -> Swagger 2.0 schema mapping (mirrors PostgREST OpenAPI.hs:59-115).

  Two modes: `schema/2` for column/definition/body properties, `query_param/2`
  for RPC GET query parameters (arrays/json collapse to string).
  """

  # {swagger type | nil, swagger format} for a scalar base type. nil type => json/jsonb.
  defp base("character varying"), do: {"string", "character varying"}
  defp base("character"), do: {"string", "character"}
  defp base("text"), do: {"string", "text"}
  defp base("boolean"), do: {"boolean", "boolean"}
  defp base("smallint"), do: {"integer", "int32"}
  defp base("integer"), do: {"integer", "int32"}
  defp base("bigint"), do: {"integer", "int64"}
  defp base("numeric"), do: {"number", "numeric"}
  defp base("real"), do: {"number", "real"}
  defp base("double precision"), do: {"number", "double precision"}
  defp base("json"), do: {nil, "json"}
  defp base("jsonb"), do: {nil, "jsonb"}

  # Fallback: unknown scalar -> string with verbatim format (matches PostgREST's permissive default).
  defp base(other), do: {"string", other}

  @doc "Schema-mode mapping (definition properties, RPC POST body properties)."
  def schema(type, opts) do
    type = normalize(type)

    cond do
      enum = Keyword.get(opts, :enum) ->
        %{"type" => "string", "format" => type, "enum" => enum}

      array_elem = array_element(type) ->
        %{"format" => type, "type" => "array", "items" => array_items(array_elem)}

      true ->
        {t, f} = base(type)
        m = if t, do: %{"type" => t, "format" => f}, else: %{"format" => f}
        maybe_max_length(m, Keyword.get(opts, :max_length))
    end
  end

  @doc "Query-param mode mapping (RPC GET parameters)."
  def query_param(type, opts) do
    type = normalize(type)

    cond do
      Keyword.get(opts, :variadic, false) ->
        elem = array_element(type) || type
        {t, f} = base(elem)
        items = if t, do: %{"type" => t, "format" => f}, else: %{"format" => f}

        %{
          "type" => "array",
          "collectionFormat" => "multi",
          "items" => items
        }

      array_element(type) ->
        %{"type" => "string", "format" => type}

      true ->
        {t, f} = base(type)
        %{"type" => t || "string", "format" => f}
    end
  end

  @doc "Decode a column default expression to a JSON value, or :omit when there is none."
  def default(nil, _type), do: :omit

  def default(raw, type) do
    stripped = strip_cast(raw)

    cond do
      type == "boolean" -> parse_bool(stripped)
      type in ["smallint", "integer", "bigint"] -> parse_int(stripped)
      type in ["numeric", "real", "double precision"] -> parse_num(stripped)
      true -> unquote_sql(stripped)
    end
  end

  # "text[]" -> "text"; non-array -> nil.
  defp array_element(type) do
    if String.ends_with?(type, "[]"), do: String.replace_suffix(type, "[]", ""), else: nil
  end

  defp array_items(elem) do
    case base(elem) do
      {nil, _} -> %{}
      {t, _} -> %{"type" => t}
    end
  end

  defp maybe_max_length(m, nil), do: m
  defp maybe_max_length(m, n), do: Map.put(m, "maxLength", n)

  # Strip PG length/precision modifiers like "(1)", "(10,2)", "(6)" while
  # preserving the rest of the type string (notably a trailing "[]").
  defp normalize(type), do: String.replace(type, ~r/\(\d[\d,\s]*\)/, "")

  defp strip_cast(s), do: s |> String.split("::", parts: 2) |> hd()

  defp unquote_sql(s) do
    s |> String.trim() |> String.trim_leading("'") |> String.trim_trailing("'")
  end

  defp parse_bool("true"), do: true
  defp parse_bool("false"), do: false
  defp parse_bool(_), do: :omit

  defp parse_int(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> :omit
    end
  end

  defp parse_num(s) do
    case Float.parse(s) do
      {f, ""} -> if f == Float.round(f) and not String.contains?(s, "."), do: trunc(f), else: f
      _ -> :omit
    end
  end
end
