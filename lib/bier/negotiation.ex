defmodule Bier.Negotiation do
  @moduledoc """
  Resolves the response media type for a request by negotiating the `Accept`
  header against the producers available in the request's context (relation,
  RPC, or root), mirroring PostgREST's content negotiation.

  Returns `{:ok, %Bier.MediaType{}}` or `{:error, {:not_acceptable, accept}}`
  where `accept` is the original `Accept` header (used to build the PGRST107
  error message).
  """

  alias Bier.MediaType
  alias Plug.Conn

  @doc """
  Negotiate for a request given the list of available producer symbols.
  `available` is an ordered list; its head is the default for `*/*`.
  """
  def resolve(%Conn{} = conn, available) do
    accept_header = accept(conn)
    accepts = MediaType.parse_accept(accept_header)

    case MediaType.negotiate(accepts, available) do
      {:ok, mt} -> {:ok, mt}
      :not_acceptable -> {:error, {:not_acceptable, accept_header || "*/*"}}
    end
  end

  @doc "The raw Accept header (or nil)."
  def accept(%Conn{} = conn) do
    case Conn.get_req_header(conn, "accept") do
      [value | _] -> value
      [] -> nil
    end
  end
end
