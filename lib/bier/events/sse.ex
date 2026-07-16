defmodule Bier.Events.SSE do
  @moduledoc """
  Pure Server-Sent Events wire encoding for the realtime events endpoint.

  Frames map a Postgres NOTIFY onto SSE's native fields: the channel name is
  the `event:` field and the payload is carried verbatim in `data:` lines —
  no envelope is invented. A payload containing line breaks (`\\n`, `\\r\\n`,
  or a bare `\\r` — all line terminators to an SSE parser) is split across
  consecutive `data:` lines, which clients reassemble joined with `\\n`; a
  raw CR left inside a `data:` line would instead be treated as a line break
  by the client's parser, silently truncating the payload after it.
  """

  @line_break ~r/\r\n|\r|\n/

  @retry_ms 3000

  @doc "Opening bytes of every stream: reconnect hint + a comment frame."
  @spec preamble() :: iodata()
  def preamble, do: "retry: #{@retry_ms}\n: connected\n\n"

  @doc "Keepalive comment written after a configured interval of silence."
  @spec heartbeat() :: iodata()
  def heartbeat, do: ": keepalive\n\n"

  @doc "One event frame: `event:` = channel, `data:` = payload verbatim."
  @spec frame(String.t(), String.t()) :: iodata()
  def frame(channel, payload) do
    data =
      payload
      |> String.split(@line_break)
      |> Enum.map(&["data: ", &1, "\n"])

    ["event: ", channel, "\n", data, "\n"]
  end
end
