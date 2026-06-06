defmodule Bier.Response do
  @moduledoc """
  Shared response rendering for read, RPC, and mutation paths: applies the
  negotiated media-type transform (`Bier.Render`), sets the `Content-Type` and
  `Content-Range`, and emits the right status.
  """

  import Plug.Conn

  alias Bier.MediaType
  alias Bier.Pagination
  alias Bier.Render

  @doc """
  Render a JSON-array result `body` for the negotiated `media`, honoring
  pagination (`Content-Range`, 200/206) and out-of-bounds offsets.

  Options: `:columns` (CSV column order), `:status` (override status for
  mutations, e.g. 201).
  """
  def render(conn, body, count, plan, count_mode, media, opts \\ []) do
    rows = row_count(body)
    offset = plan_offset(plan)
    total = if count_mode == :none, do: nil, else: count

    if Pagination.out_of_bounds?(offset, rows, total) do
      out_of_bounds(conn, offset, total)
    else
      case Render.render(media, body, columns: opts[:columns]) do
        {:ok, payload} ->
          range = Pagination.content_range(offset, rows, total)
          status = opts[:status] || Pagination.status(offset, rows, total)
          out = response_body(conn, payload)

          conn
          |> put_resp_header("content-type", MediaType.content_type(media))
          |> put_resp_header("content-range", range)
          |> put_resp_header("content-length", Integer.to_string(byte_size(out)))
          |> send_resp(status, out)

        {:error, _} = err ->
          err
      end
    end
  end

  defp plan_offset(%{offset: offset}), do: offset || 0
  defp plan_offset(_), do: 0

  defp response_body(%Plug.Conn{method: "HEAD"}, _body), do: ""
  defp response_body(_conn, body), do: body

  defp out_of_bounds(conn, offset, total) do
    body = %{
      message: "Requested range not satisfiable",
      code: "PGRST103",
      details: "An offset of #{offset} was requested, but there are only #{total} rows.",
      hint: nil
    }

    payload = Bier.json_library().encode!(body)

    conn
    |> put_resp_content_type("application/json", "utf-8")
    |> put_resp_header("content-range", "*/#{total}")
    |> send_resp(416, payload)
  end

  @doc "Cheap row count without decoding when possible."
  def row_count("[]"), do: 0
  def row_count("null"), do: 0

  def row_count(body) do
    case Bier.json_library().decode(body) do
      {:ok, list} when is_list(list) -> length(list)
      _ -> 0
    end
  end
end
