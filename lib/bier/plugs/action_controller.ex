defmodule Bier.Plugs.ActionController do
  @moduledoc """
  API controller
  """

  @behaviour Plug

  import Plug.Conn

  alias Bier.Plugs.FallbackController

  @impl Plug
  def init(config), do: config

  @impl Plug
  def call(conn, action) when action in [:index, :post, :delete] do
    case apply(__MODULE__, action, [conn, conn.params]) do
      %Plug.Conn{} = conn ->
        conn

      error ->
        FallbackController.call(conn, error)
    end
  end

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    json(conn, [%{key: "hello"}])
  end

  @spec post(Plug.Conn.t(), map()) :: Plug.Conn.t() | {:error, :mismatch}
  def post(conn, _params) do
    conn
    |> put_status(:created)
    |> json(%{key: "new"})
  end

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, _params) do
    conn
    |> resp(:no_content, "")
    |> send_resp()
  end

  defp json(conn, data) do
    response = Bier.json_library().encode_to_iodata!(data)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(conn.status || :ok, response)
  end
end
