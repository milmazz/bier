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
    url = Bier.ConformanceServer.base_url() <> encode_target(Map.fetch!(req, "path"))

    resp =
      Req.request!(
        method: method,
        url: url,
        headers: build_headers(req, schema),
        body: request_body(req),
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

  # Characters that are invalid in an HTTP request target (RFC 3986/7230) and so
  # are rejected client-side by Req/Mint before the request is ever sent. The
  # conformance cases carry raw query grammar (json-path `->`/`->>`, quantifier
  # `{3,4}`, literal spaces, quoted `"` values, literal `%` LIKE wildcards), so
  # we percent-encode exactly this set — plus raw non-ASCII bytes and any literal
  # `%` that is NOT already a valid `%XX` escape — while leaving existing `%XX`,
  # `+` (server decodes to space), and the reserved delimiters
  # (`,` `(` `)` `=` `&` `?` `/` `.` `:` `*`) untouched. The server
  # percent-decodes back to the identical logical request, so this only fixes
  # client-side deliverability, not behavior.
  @target_unsafe ~c" \"<>{}|\\^`"

  defguardp is_hex(c) when c in ?0..?9 or c in ?A..?F or c in ?a..?f

  defp encode_target(path), do: IO.iodata_to_binary(encode_chars(path))

  # An existing `%XX` escape (e.g. %20, %22, %D9 in already-encoded cases) is
  # preserved verbatim; any other `%` is a literal and gets encoded to %25.
  defp encode_chars(<<?%, a, b, rest::binary>>) when is_hex(a) and is_hex(b),
    do: [<<?%, a, b>> | encode_chars(rest)]

  defp encode_chars(<<byte, rest::binary>>), do: [encode_byte(byte) | encode_chars(rest)]
  defp encode_chars(<<>>), do: []

  defp encode_byte(byte)
       when byte < 0x20 or byte == 0x7F or byte >= 0x80 or byte == ?% or byte in @target_unsafe,
       do: "%" <> (byte |> Integer.to_string(16) |> String.upcase() |> String.pad_leading(2, "0"))

  defp encode_byte(byte), do: <<byte>>

  # A case carries at most one request-body form:
  #   * `body_raw`  — sent verbatim (CSV, deliberately-invalid JSON, octet bytes)
  #   * `body_json` — the value is always JSON-encoded
  #   * `body`      — JSON-encoded unless already a string
  defp request_body(%{"body_raw" => raw}), do: raw
  defp request_body(%{"body_json" => json}), do: Bier.json_library().encode!(json)
  defp request_body(%{"body" => body}), do: encode_body(body)
  defp request_body(_), do: nil

  defp encode_body(nil), do: nil
  defp encode_body(body) when is_binary(body), do: body
  defp encode_body(body), do: Bier.json_library().encode!(body)

  # Req returns headers as %{"name" => [values]} with downcased names.
  defp normalize_headers(headers) do
    Map.new(headers, fn {k, v} -> {String.downcase(k), v |> List.wrap() |> Enum.join(", ")} end)
  end

  defp to_method(str), do: Map.fetch!(@http_methods, String.upcase(str))
end
