defmodule Bier.RequestLogTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Bier.RequestLog

  # ---- should_log?/2 (PostgREST Logger.hs shouldLogResponse) ---------------

  describe "should_log?/2" do
    test "crit logs nothing" do
      refute RequestLog.should_log?(:crit, 200)
      refute RequestLog.should_log?(:crit, 500)
    end

    test "error (the default) logs only >= 500" do
      refute RequestLog.should_log?(:error, 200)
      refute RequestLog.should_log?(:error, 404)
      assert RequestLog.should_log?(:error, 500)
      assert RequestLog.should_log?(:error, 503)
    end

    test "warn logs only >= 400" do
      refute RequestLog.should_log?(:warn, 200)
      assert RequestLog.should_log?(:warn, 400)
      assert RequestLog.should_log?(:warn, 500)
    end

    test "info and debug log everything" do
      assert RequestLog.should_log?(:info, 200)
      assert RequestLog.should_log?(:debug, 200)
    end
  end

  # ---- access_line/3 (Apache combined; test_io.py#L728 shape) --------------

  describe "access_line/3" do
    defp resp_conn do
      :get
      |> conn("/items?select=id")
      |> Plug.Conn.put_req_header("user-agent", "req/0.5")
      |> Plug.Conn.resp(404, ~s({"code":"PGRST"}))
    end

    test "renders host/ident dashes, role, request line, status, bytes, referer, agent" do
      line = RequestLog.access_line(resp_conn(), "web_anon", ~U[2026-08-07 07:30:00Z])

      assert line ==
               ~s(- - web_anon [07/Aug/2026:07:30:00 +0000] ) <>
                 ~s("GET /items?select=id HTTP/1.1" 404 16 "" "req/0.5")
    end

    test "a nil role renders as a dash (pre-role-resolution failures)" do
      line = RequestLog.access_line(resp_conn(), nil, ~U[2026-08-07 07:30:00Z])
      assert line =~ ~r|^- - - \[|
    end

    test "matches the upstream io-test pattern" do
      line = RequestLog.access_line(resp_conn(), "web_anon", DateTime.utc_now())

      assert line =~
               ~r|^- - web_anon \[.+\] "GET /items\?select=id HTTP/1.1" 404 \d+ "" "req/0.5"$|
    end

    test "a referer is included inside its quotes; no query string, no question mark" do
      line =
        :get
        |> conn("/items")
        |> Plug.Conn.put_req_header("referer", "http://example.com/")
        |> Plug.Conn.resp(200, "[]")
        |> RequestLog.access_line("r", ~U[2026-08-07 07:30:00Z])

      assert line =~ ~s("GET /items HTTP/1.1" 200 2 "http://example.com/" "")
    end
  end

  # ---- the per-request SQL accumulator (log-query) -------------------------

  describe "sql accumulator" do
    test "records in order when armed, drains once" do
      RequestLog.arm(true)
      RequestLog.record("SELECT 1")
      RequestLog.record("SELECT 2")

      assert RequestLog.drain() == ["SELECT 1", "SELECT 2"]
      assert RequestLog.drain() == []
    end

    test "records nothing when disarmed" do
      RequestLog.arm(false)
      RequestLog.record("SELECT 1")
      assert RequestLog.drain() == []
    end

    test "re-arming clears leftovers from a previous request on the same process" do
      RequestLog.arm(true)
      RequestLog.record("SELECT stale")
      RequestLog.arm(true)
      RequestLog.record("SELECT fresh")
      assert RequestLog.drain() == ["SELECT fresh"]
    end
  end
end
