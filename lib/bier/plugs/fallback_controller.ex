defmodule Bier.Plugs.FallbackController do
  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(config), do: config

  @impl Plug
  # handle resources that cannot be found.
  def call(conn, :not_found) do
    response = ~s|{"error_code": 404, "error_message": "Not found"}|

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(:not_found, response)
  end

  def call(conn, {:error, :bad_request}) do
    conn
    |> put_status(:bad_request)
    |> json(%{code: :bad_request, message: "Bad Request"})
  end

  def call(conn, {:error, :mismatch}) do
    conn
    |> put_status(:bad_request)
    |> json(%{code: :mismatch, message: "All object keys must match"})
  end

  def call(conn, %{code: :insufficient_privilege} = error) do
    conn
    |> put_status(:unauthorized)
    |> json(error)
  end

  def call(conn, %{code: :foreign_key_violation} = error) do
    conn
    |> put_status(:bad_request)
    |> json(error)
  end

  defp json(conn, data) do
    response = Bier.json_library().encode_to_iodata!(data)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(conn.status || :ok, response)
  end
end
