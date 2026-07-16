defmodule Bier.OpenAPI.V3 do
  @moduledoc """
  Converts the generated Swagger 2.0 root document (`Bier.OpenAPI.build/1`)
  into an OpenAPI 3.0.3 document.

  Opt-in via the `openapi_version: "3.0"` config option; the default remains
  the PostgREST-parity Swagger 2.0 wire format. Converting the finished 2.0
  map (rather than emitting 3.0 from the introspection model in parallel)
  keeps a single wire-format source of truth: parity fixes to the 2.0
  emitter propagate here automatically. PostgREST core has no OpenAPI 3.x
  emitter (PostgREST/postgrest#932), so this output has no conformance
  surface and is shaped by the OpenAPI 3.0.3 spec alone.

  The converter is intentionally NOT general purpose: it handles exactly the
  shapes the 2.0 emitter produces (body params only as `body.*` shared
  definitions or the inline RPC `args`, `application/json` as the implied
  media type, `collectionFormat: "multi"` only on query params).
  """

  @json "application/json"

  # Parameter-object keys that stay at the parameter level in 3.0; everything
  # else (type/format/enum/default/maxLength/items/...) nests under "schema".
  @param_keys ~w(name in required description)

  @doc "Converts a Swagger 2.0 document map into an OpenAPI 3.0.3 one."
  @spec convert(map()) :: map()
  def convert(doc) do
    {bodies, params} = split_shared_params(doc["parameters"] || %{})

    components =
      %{}
      |> put_nonempty("schemas", rewrite_refs(doc["definitions"] || %{}))
      |> put_nonempty("parameters", Map.new(params, fn {k, p} -> {k, convert_param(p)} end))
      |> put_nonempty("requestBodies", Map.new(bodies, fn {k, p} -> {k, convert_body(p)} end))
      |> put_nonempty("securitySchemes", doc["securityDefinitions"])

    body_keys = bodies |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    %{
      "openapi" => "3.0.3",
      "info" => doc["info"],
      "externalDocs" => doc["externalDocs"],
      "servers" => servers(doc),
      "paths" => convert_paths(doc["paths"] || %{}, body_keys),
      "components" => components
    }
    |> put_nonempty("security", doc["security"])
  end

  defp put_nonempty(map, _k, v) when v in [nil, %{}], do: map
  defp put_nonempty(map, k, v), do: Map.put(map, k, v)

  # ---- servers -------------------------------------------------------------

  # With a proxy the 2.0 doc carries schemes/host/basePath; fold them into one
  # server URL. Without one, the API lives at the document root.
  defp servers(%{"host" => host, "schemes" => [scheme | _]} = doc) do
    base = if doc["basePath"] in [nil, "/"], do: "", else: doc["basePath"]
    [%{"url" => "#{scheme}://#{host}#{base}"}]
  end

  defp servers(_doc), do: [%{"url" => "/"}]

  # ---- shared parameters ---------------------------------------------------

  defp split_shared_params(params) do
    Enum.split_with(params, fn {_k, p} -> p["in"] == "body" end)
  end

  defp convert_body(p) do
    %{
      "required" => p["required"],
      "content" => %{@json => %{"schema" => rewrite_refs(p["schema"])}}
    }
    |> put_nonempty("description", p["description"])
  end

  defp convert_param(p) do
    {kept, schema_keys} = Map.split(p, @param_keys)

    schema =
      case Map.pop(schema_keys, "collectionFormat") do
        {"multi", rest} -> rest
        {nil, rest} -> rest
      end
      |> rewrite_refs()

    kept
    |> Map.put("schema", schema)
    |> then(fn param ->
      if schema_keys["collectionFormat"] == "multi",
        do: Map.merge(param, %{"style" => "form", "explode" => true}),
        else: param
    end)
  end

  # ---- paths ---------------------------------------------------------------

  defp convert_paths(paths, body_keys) do
    Map.new(paths, fn {path, item} ->
      {path, Map.new(item, fn {verb, op} -> {verb, convert_operation(op, body_keys)} end)}
    end)
  end

  defp convert_operation(op, body_keys) do
    {body, params} = extract_body(op["parameters"] || [], body_keys)

    op
    |> Map.put("parameters", Enum.map(params, &convert_op_param/1))
    |> Map.update("responses", %{}, &convert_responses/1)
    |> put_nonempty("requestBody", body)
    |> then(fn converted ->
      if converted["parameters"] == [], do: Map.delete(converted, "parameters"), else: converted
    end)
  end

  # One body param at most per operation (the 2.0 emitter guarantees it):
  # either a $ref to a shared body.<table> definition or the inline RPC args.
  defp extract_body(parameters, body_keys) do
    Enum.reduce(parameters, {nil, []}, fn param, {body, rest} ->
      case param do
        %{"$ref" => "#/parameters/" <> key} ->
          if MapSet.member?(body_keys, key) do
            {%{"$ref" => "#/components/requestBodies/#{key}"}, rest}
          else
            {body, rest ++ [param]}
          end

        %{"in" => "body"} = inline ->
          {%{
             "required" => inline["required"],
             "content" => %{@json => %{"schema" => rewrite_refs(inline["schema"])}}
           }, rest}

        inline ->
          {body, rest ++ [inline]}
      end
    end)
  end

  defp convert_op_param(%{"$ref" => "#/parameters/" <> key}),
    do: %{"$ref" => "#/components/parameters/#{key}"}

  defp convert_op_param(inline), do: convert_param(inline)

  defp convert_responses(responses) do
    Map.new(responses, fn
      {status, %{"schema" => schema} = resp} ->
        {status,
         resp
         |> Map.delete("schema")
         |> Map.put("content", %{@json => %{"schema" => rewrite_refs(schema)}})}

      {status, resp} ->
        {status, resp}
    end)
  end

  # ---- $ref rewriting ------------------------------------------------------

  # Walks any JSON-ish term and repoints definition refs at components.
  defp rewrite_refs(%{} = map) do
    Map.new(map, fn
      {"$ref", "#/definitions/" <> name} -> {"$ref", "#/components/schemas/#{name}"}
      {k, v} -> {k, rewrite_refs(v)}
    end)
  end

  defp rewrite_refs(list) when is_list(list), do: Enum.map(list, &rewrite_refs/1)
  defp rewrite_refs(other), do: other
end
