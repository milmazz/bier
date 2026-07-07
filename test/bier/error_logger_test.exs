defmodule Bier.ErrorLoggerTest do
  @moduledoc """
  Exercises the structured JSON error logging for PostgREST's PGRST001/PGRST002
  conditions (#27): the envelope shape, and the schema-cache load funnel that
  emits PGRST002 on a failing introspection.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Bier.ErrorLogger

  test "database_client_error logs the PGRST001 envelope" do
    err = %DBConnection.ConnectionError{message: "tcp recv: closed"}

    log = capture_log(fn -> ErrorLogger.database_client_error(SomeInstance, err) end)

    assert %{
             "code" => "PGRST001",
             "message" => "Database client error. Retrying the connection.",
             "details" => "tcp recv: closed",
             "hint" => nil
           } == extract_envelope(log)
  end

  test "schema_cache_load_error logs the PGRST002 envelope" do
    err = %DBConnection.ConnectionError{message: "connection refused"}

    log = capture_log(fn -> ErrorLogger.schema_cache_load_error(SomeInstance, err) end)

    assert %{
             "code" => "PGRST002",
             "message" => "Could not query the database for the schema cache. Retrying.",
             "details" => "connection refused",
             "hint" => nil
           } == extract_envelope(log)
  end

  test "a non-exception reason is inspected into details" do
    log = capture_log(fn -> ErrorLogger.database_client_error(SomeInstance, :closed) end)

    assert %{"code" => "PGRST001", "details" => ":closed"} = extract_envelope(log)
  end

  test "a failing schema-cache load logs PGRST002 through the load! funnel" do
    # An unregistered pool name: the introspection's checkout exits with
    # :noproc, which load! logs as PGRST002 and then re-exits.
    name = Module.concat(__MODULE__, "Down#{System.unique_integer([:positive])}")
    conn = Bier.Registry.via(name, Postgrex)

    log =
      capture_log(fn ->
        catch_exit(Bier.SchemaCache.load!(name, conn, ["public"]))
      end)

    assert %{
             "code" => "PGRST002",
             "message" => "Could not query the database for the schema cache. Retrying.",
             "hint" => nil
           } = extract_envelope(log)
  end

  # The envelope is the whole Logger message: one JSON object per log line.
  defp extract_envelope(log) do
    [json] = Regex.run(~r/\{.*\}/, log)
    Bier.json_library().decode!(json)
  end
end
