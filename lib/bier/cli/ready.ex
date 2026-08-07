defmodule Bier.CLI.Ready do
  @moduledoc """
  The client half of the `--ready` flag (PostgREST `Client.hs`): GET the admin
  server's `/ready` endpoint and report the outcome the way PostgREST's
  http-client wrapper does — `OK: <url>` on a 2xx, `ERROR: <url>` on any other
  response, `ERROR: connection refused to <url>` when the request fails.

  Kept out of `Bier.CLI.run/2` so the core stays IO-free: `run/2` returns
  `{:ready, url}` (or the config-derived failures directly) and `main/1` calls
  `check/1` to perform the request.
  """

  # http-client's default manager waits 30s for a response; mirror that rather
  # than :httpc's infinity.
  @timeout_ms 30_000

  @doc "GET `url` and map the outcome to a `%{stdout, stderr, exit}` result."
  @spec check(String.t()) :: Bier.CLI.result()
  def check(url) do
    {:ok, _} = Application.ensure_all_started(:inets)

    request = {String.to_charlist(url), []}

    case :httpc.request(:get, request, [timeout: @timeout_ms], body_format: :binary) do
      {:ok, {{_version, status, _reason}, _headers, _body}} when status in 200..299 ->
        %{stdout: "OK: #{url}\n", stderr: "", exit: 0}

      {:ok, _response} ->
        %{stdout: "", stderr: "ERROR: #{url}\n", exit: 1}

      # PostgREST collapses every transport-level failure into the
      # connection-refused message (Client.hs handleHttpException).
      {:error, _reason} ->
        %{stdout: "", stderr: "ERROR: connection refused to #{url}\n", exit: 1}
    end
  end
end
