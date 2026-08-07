defmodule Bier.CancellationTest do
  @moduledoc """
  Unit tests for `Bier.Cancellation` — the adapter-shape fallback paths that
  need no real HTTP server. The end-to-end disconnect behavior is covered by
  `Bier.CancellationHttpTest`.
  """
  use ExUnit.Case, async: true

  import Plug.Test

  test "runs the fun inline when the adapter exposes no watchable socket" do
    conn = conn(:get, "/things")

    assert {:ok, :result} =
             Bier.Cancellation.run(conn, %{name: :cancellation_unit}, fn -> {:ok, :result} end)
  end

  test "cancel_on_disconnect defaults to true and validates as a boolean" do
    assert Bier.Config.new!([], Bier.schema()).cancel_on_disconnect == true

    assert_raise ArgumentError, ~r/cancel_on_disconnect/, fn ->
      Bier.Config.new!([cancel_on_disconnect: "nope"], Bier.schema())
    end
  end
end
