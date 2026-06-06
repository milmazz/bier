defmodule Bier.Plugs.ReadBody do
  @moduledoc """
  Reads the full raw request body once, caching it in
  `conn.assigns[:bier_raw_body]`, and JSON-parses it into `conn.body_params`
  when the request `Content-Type` is JSON.

  PostgREST-style content negotiation needs the raw body for non-JSON request
  payloads (CSV inserts, octet-stream RPC) which `Plug.Parsers` would otherwise
  discard, while still decoding JSON bodies for the read/RPC paths. This plug
  replaces `Plug.Parsers` so a single read serves every content type.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    {:ok, body, conn} = read_full_body(conn, "")
    conn = assign(conn, :bier_raw_body, body)

    if json?(conn) and body != "" do
      case Bier.json_library().decode(body) do
        {:ok, params} when is_map(params) -> %{conn | body_params: params}
        {:ok, params} when is_list(params) -> %{conn | body_params: %{"_json" => params}}
        _ -> conn
      end
    else
      conn
    end
  end

  defp read_full_body(conn, acc) do
    case read_body(conn) do
      {:ok, chunk, conn} -> {:ok, acc <> chunk, conn}
      {:more, chunk, conn} -> read_full_body(conn, acc <> chunk)
      {:error, _} = err -> err
    end
  end

  defp json?(conn) do
    case get_req_header(conn, "content-type") do
      [value | _] -> String.contains?(String.downcase(value), "json")
      [] -> false
    end
  end
end
