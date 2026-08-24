defmodule Bier.AccessLogHttpTest do
  @moduledoc """
  End-to-end access-log behavior (#28) against live instances: which responses
  produce an Apache-combined line for each `log_level`, the line's shape
  (PostgREST `test_io.py` log tests), and `log_query` SQL emission.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  defp start_listening_instance(name, extra_opts) do
    port = free_port()

    {:ok, pid} =
      Bier.start_link(
        [name: name, router: [port: port, scheme: :http]] ++
          Keyword.merge(Bier.ConformanceServer.base_opts(), extra_opts)
      )

    on_exit(fn -> stop(pid) end)
    wait_until_listening(port)
    "http://127.0.0.1:#{port}"
  end

  defp stop(pid) do
    if Process.alive?(pid), do: Supervisor.stop(pid)
  catch
    :exit, _ -> :ok
  end

  # Delegates to the shared helper rather than re-probing an ephemeral
  # port: those come from the same range the suite's own outgoing
  # connections use, so one could be taken between the probe closing and
  # this instance binding it — an :eaddrinuse that surfaces as an
  # unrelated test failure. `Bier.TestPorts` also reserves what it hands
  # out, so two callers cannot receive the same port.
  defp free_port, do: Bier.TestPorts.free_port()

  defp wait_until_listening(port, retries \\ 100) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [], 10) do
      {:ok, sock} ->
        :gen_tcp.close(sock)

      {:error, _} when retries > 0 ->
        Process.sleep(10)
        wait_until_listening(port, retries - 1)
    end
  end

  defp unique_name, do: :"access_log_#{System.unique_integer([:positive])}"

  test "log_level info emits the Apache-combined line for a 200" do
    base = start_listening_instance(unique_name(), log_level: :info)

    log =
      capture_log(fn ->
        assert Req.get!(base <> "/items?select=id", retry: false).status == 200
      end)

    assert log =~ ~r|- - - \[.+\] "GET /items\?select=id HTTP/1.1" 200 \d+ "" "req/.+"|
  end

  test "the default log_level (error) stays silent for 2xx and 4xx but logs 5xx-free requests nothing" do
    base = start_listening_instance(unique_name(), [])

    log =
      capture_log(fn ->
        assert Req.get!(base <> "/items", retry: false).status == 200
        assert Req.get!(base <> "/unknown_relation", retry: false).status == 404
      end)

    refute log =~ ~s("GET /items HTTP/1.1")
    refute log =~ ~s("GET /unknown_relation HTTP/1.1")
  end

  test "log_level warn logs the 404 but not the 200" do
    base = start_listening_instance(unique_name(), log_level: :warn)

    log =
      capture_log(fn ->
        assert Req.get!(base <> "/items", retry: false).status == 200
        assert Req.get!(base <> "/unknown_relation", retry: false).status == 404
      end)

    refute log =~ ~s("GET /items HTTP/1.1")
    assert log =~ ~r|- - - \[.+\] "GET /unknown_relation HTTP/1.1" 404 \d+ "" "req/.+"|
  end

  test "log_query records and emits the main SQL under the same status filter" do
    base = start_listening_instance(unique_name(), log_level: :info, log_query: true)

    log =
      capture_log(fn ->
        assert Req.get!(base <> "/items?select=id", retry: false).status == 200
      end)

    # The one parameterized main query is logged on a single line alongside
    # the access line.
    assert log =~ ~r|- - - \[.+\] "GET /items\?select=id HTTP/1.1" 200|
    assert log =~ "SELECT"
    assert log =~ "items"
  end

  test "the user field carries the resolved role, including the anon role (test_io.py)" do
    name = unique_name()
    port = free_port()

    {:ok, pid} =
      Bier.start_link(
        [name: name, router: [port: port, scheme: :http], log_level: :info] ++
          Keyword.merge(Bier.ConformanceServer.base_opts() |> Keyword.delete(:log_level),
            db_anon_role: "postgrest_test_anonymous",
            jwt_secret: "reallyreallyreallyreallyverysafe"
          )
      )

    on_exit(fn -> stop(pid) end)
    wait_until_listening(port)

    log =
      capture_log(fn ->
        assert Req.get!("http://127.0.0.1:#{port}/items", retry: false).status == 200
      end)

    assert log =~ ~r|- - postgrest_test_anonymous \[.+\] "GET /items HTTP/1.1" 200|
  end

  test "log_query off logs no SQL even at info" do
    base = start_listening_instance(unique_name(), log_level: :info)

    log =
      capture_log(fn ->
        assert Req.get!(base <> "/items", retry: false).status == 200
      end)

    refute log =~ "SELECT"
  end
end
