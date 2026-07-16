defmodule Bier.Events.SSETest do
  use ExUnit.Case, async: true

  alias Bier.Events.SSE

  defp bin(iodata), do: IO.iodata_to_binary(iodata)

  test "frame/2 sets the channel as the SSE event name and the payload verbatim" do
    assert bin(SSE.frame("chat", ~s({"msg":"hi"}))) ==
             "event: chat\ndata: {\"msg\":\"hi\"}\n\n"
  end

  test "frame/2 splits multi-line payloads across data: lines" do
    assert bin(SSE.frame("chat", "line1\nline2")) ==
             "event: chat\ndata: line1\ndata: line2\n\n"
  end

  test "frame/2 treats CR and CRLF as line terminators like the SSE spec" do
    # A data: line containing a raw CR would be split at the CR by the
    # client's EventSource parser, silently dropping the tail of the payload.
    assert bin(SSE.frame("chat", "line1\rline2")) ==
             "event: chat\ndata: line1\ndata: line2\n\n"

    assert bin(SSE.frame("chat", "line1\r\nline2")) ==
             "event: chat\ndata: line1\ndata: line2\n\n"
  end

  test "frame/2 emits a data: line for an empty payload so the client event fires" do
    assert bin(SSE.frame("chat", "")) == "event: chat\ndata: \n\n"
  end

  test "heartbeat/0 is an SSE comment" do
    assert bin(SSE.heartbeat()) == ": keepalive\n\n"
  end

  test "preamble/0 carries the retry hint and a connected comment" do
    assert bin(SSE.preamble()) == "retry: 3000\n: connected\n\n"
  end
end
