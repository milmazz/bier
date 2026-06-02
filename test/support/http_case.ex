defmodule Bier.HttpCase do
  @moduledoc """
  ExUnit case template for conformance tests. Provides `perform/1`, which runs a
  `Bier.ConformanceCase` against the shared Bier instance and returns a
  normalized `%{status:, headers:, body:}` map (header keys downcased), plus the
  assertion helpers.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import Bier.HttpCase
      import Bier.ConformanceAssertions
    end
  end

  @http_methods %{
    "GET" => :get,
    "POST" => :post,
    "PATCH" => :patch,
    "PUT" => :put,
    "DELETE" => :delete,
    "HEAD" => :head,
    "OPTIONS" => :options
  }

  @doc "Run an HTTP conformance case against the shared instance."
  def perform(%Bier.ConformanceCase{request: req, schema: schema}) do
    method = to_method(Map.get(req, "method", "GET"))
    url = Bier.ConformanceServer.base_url() <> Map.fetch!(req, "path")

    resp =
      Req.request!(
        method: method,
        url: url,
        headers: build_headers(req, schema),
        body: encode_body(Map.get(req, "body")),
        decode_body: false,
        retry: false
      )

    %{status: resp.status, headers: normalize_headers(resp.headers), body: resp.body}
  end

  defp build_headers(req, schema) do
    base = Map.get(req, "headers", %{})
    # "public"/nil is the default schema. "test" is the conformance suite's own
    # schema name; Bier does not yet support Accept-Profile schema routing, so
    # suppress the header to avoid spurious 400s. Revisit "test" once schema
    # routing is implemented.
    if schema in [nil, "public", "test"] do
      base
    else
      Map.put_new(base, "Accept-Profile", schema)
    end
  end

  defp encode_body(nil), do: nil
  defp encode_body(body) when is_binary(body), do: body
  defp encode_body(body), do: Bier.json_library().encode!(body)

  # Req returns headers as %{"name" => [values]} with downcased names.
  defp normalize_headers(headers) do
    Map.new(headers, fn {k, v} -> {String.downcase(k), v |> List.wrap() |> Enum.join(", ")} end)
  end

  defp to_method(str), do: Map.fetch!(@http_methods, String.upcase(str))
end
