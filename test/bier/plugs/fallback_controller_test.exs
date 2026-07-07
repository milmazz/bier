defmodule Bier.Plugs.FallbackControllerTest do
  @moduledoc """
  Exercises the out-of-band observability added to the fallback controller
  (#27/#36): PGRST001 logging and the pool checkout-timeout telemetry counter
  for connection errors. The wire format (status/body/headers) must stay
  exactly what the catch-all already rendered — asserted here too.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Test

  alias Bier.Plugs.FallbackController

  test "a pool queue timeout renders the opaque 500, logs PGRST001, and bumps the counter" do
    name = unique_name()
    ref = attach([[:bier, :pool, :checkout_timeout]], name)

    err = %DBConnection.ConnectionError{
      message: "connection not available and request was dropped from queue after 100ms",
      reason: :queue_timeout
    }

    {conn, log} = with_log(fn -> FallbackController.call(build_conn(name), {:error, err}) end)

    # The response is byte-for-byte what the catch-all rendered before #27.
    assert conn.status == 500

    assert Bier.json_library().decode!(conn.resp_body) == %{
             "code" => "PGRST",
             "message" => "Internal Server Error",
             "details" => nil,
             "hint" => nil
           }

    assert Plug.Conn.get_resp_header(conn, "proxy-status") == ["PostgREST; error=PGRST"]

    assert log =~ "PGRST001"
    assert log =~ "Database client error. Retrying the connection."

    assert_receive {^ref, [:bier, :pool, :checkout_timeout], %{count: 1}, %{instance: ^name}}
  end

  test "a non-timeout connection error logs PGRST001 but emits no timeout event" do
    name = unique_name()
    ref = attach([[:bier, :pool, :checkout_timeout]], name)

    err = %DBConnection.ConnectionError{message: "tcp recv: closed", reason: :error}

    {conn, log} = with_log(fn -> FallbackController.call(build_conn(name), {:error, err}) end)

    assert conn.status == 500
    assert log =~ "PGRST001"
    refute_receive {^ref, [:bier, :pool, :checkout_timeout], _, _}
  end

  test "a Postgrex client error (no SQLSTATE) keeps its message and logs PGRST001" do
    name = unique_name()
    err = %Postgrex.Error{message: "connection is closed"}

    {conn, log} = with_log(fn -> FallbackController.call(build_conn(name), {:error, err}) end)

    assert conn.status == 500
    assert %{"code" => "PGRST", "message" => "connection is closed"} = decode_body(conn)
    assert log =~ "PGRST001"
  end

  # ---- helpers -------------------------------------------------------------

  defp unique_name do
    Module.concat(__MODULE__, "I#{System.unique_integer([:positive])}")
  end

  defp build_conn(name) do
    :get
    |> conn("/items")
    |> Plug.Conn.assign(:supervisor_name, name)
  end

  defp decode_body(conn), do: Bier.json_library().decode!(conn.resp_body)

  # Same pattern as Bier.TelemetryTest: forward only events for this test's
  # instance name, via a captured module function (no closure perf warning).
  defp attach(events, name) do
    ref = make_ref()
    handler_id = {__MODULE__, ref}
    config = %{pid: self(), ref: ref, name: name}

    :telemetry.attach_many(handler_id, events, &__MODULE__.forward/4, config)
    on_exit(fn -> :telemetry.detach(handler_id) end)
    ref
  end

  @doc false
  def forward(event, measurements, metadata, %{pid: pid, ref: ref, name: name}) do
    if metadata[:instance] == name, do: send(pid, {ref, event, measurements, metadata})
  end
end
