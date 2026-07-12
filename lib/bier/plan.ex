defmodule Bier.Plan do
  @moduledoc """
  Serves the `application/vnd.pgrst.plan` media type by running `EXPLAIN` over
  the request's read query and returning the planner output (JSON or text).

  The response `Content-Type` echoes the plan format, the `for=` target media
  type, and any `options=` exactly as PostgREST does (see `Bier.MediaType`).
  """

  import Plug.Conn

  alias Bier.MediaType
  alias Bier.QueryExecutor

  @doc """
  Run the EXPLAIN for a relation read query and render the plan response.
  """
  def explain(conn, pool, relation, plan, %MediaType{symbol: :plan} = media) do
    {format, _} = {media.params.format, media.params}

    with {:ok, sql, params} <-
           Bier.ServerTiming.measure(:plan, fn ->
             QueryExecutor.build(
               relation,
               plan,
               relations(conn),
               :json,
               Bier.Pagination.count_mode(conn)
             )
           end) do
      explain_sql = "EXPLAIN (#{explain_opts(format, media)}) " <> sql

      Bier.ServerTiming.measure(:transaction, fn ->
        Postgrex.query(pool, explain_sql, params)
      end)
      |> case do
        {:ok, %Postgrex.Result{rows: rows}} ->
          body = plan_body(format, rows)

          conn
          |> put_resp_header("content-type", MediaType.content_type(media))
          |> put_resp_header("content-range", "*/*")
          |> send_resp(200, body)

        {:error, _} = err ->
          err
      end
    end
  end

  defp relations(conn) do
    Bier.SchemaCache.relations(conn.assigns.supervisor_name)
  end

  defp explain_opts(:json, media), do: "FORMAT JSON#{buffers(media)}"
  defp explain_opts(:text, media), do: "FORMAT TEXT#{buffers(media)}"

  # The `buffers` option is only valid with ANALYZE in older PGs; PostgREST runs
  # it standalone (PG16+). To stay robust across versions we omit ANALYZE-only
  # options and just echo them in the Content-Type (already handled).
  defp buffers(_media), do: ""

  defp plan_body(:json, [[json] | _]) when is_binary(json), do: json
  defp plan_body(:json, [[json] | _]), do: Bier.json_library().encode!(json)
  defp plan_body(:text, rows), do: rows |> Enum.map_join("\n", fn [line] -> line end)
  defp plan_body(_format, _rows), do: ""
end
