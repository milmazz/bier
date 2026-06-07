defmodule Bier.Plugs.AdminRouter do
  @moduledoc """
  Minimal plug for a `Bier` instance's admin server (PostgREST admin server).

  Served on its own Bandit listener bound to `admin_server_port`, kept separate
  from the catch-all API router so the health paths never collide with table
  names. Exposes:

    * `GET /live`  — `200` whenever the process is up (pure liveness).
    * `GET /ready` — `200` when `Bier.Health.ready?/1` holds, else `503`.

  Every other request returns `404`. The instance name is supplied via
  `init/1` (`name:`) so readiness resolves the right pool and schema cache.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: Keyword.fetch!(opts, :name)

  @impl Plug
  def call(%Plug.Conn{method: "GET", path_info: ["live"]} = conn, _name) do
    send_resp(conn, 200, "")
  end

  def call(%Plug.Conn{method: "GET", path_info: ["ready"]} = conn, name) do
    status = if Bier.Health.ready?(name), do: 200, else: 503
    send_resp(conn, status, "")
  end

  def call(conn, _name) do
    send_resp(conn, 404, "")
  end
end
