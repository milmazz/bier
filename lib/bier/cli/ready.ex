defmodule Bier.CLI.Ready do
  @moduledoc """
  The client half of the `--ready` flag (PostgREST `Client.hs`): GET the admin
  server's `/ready` endpoint and report the outcome the way PostgREST's
  http-client wrapper does — `OK: <url>` on a 2xx, `ERROR: <url>` on any other
  response, `ERROR: connection refused to <url>` when the request fails, and
  `ERROR: invalid url - <url>` when the URL itself cannot be parsed.

  `Bier.CLI.run/2` calls `check/1` itself once `dispatch(:ready, …)` has
  resolved a URL, so `--ready` answers with the same `%{stdout, stderr, exit}`
  result shape as every other terminal command — the probe is what the command
  *is*, and the conformance suite drives it through `run/2` like the rest.
  """

  # http-client's default manager waits 30s for a response; mirror that rather
  # than :httpc's infinity.
  @timeout_ms 30_000

  @doc """
  Validate `url` the way http-client's `parseRequest` does, before any socket
  is opened: an unparseable URL — e.g. the negative port a misconfigured
  `admin-server-port` produces — raises `InvalidUrlException`, which
  PostgREST's `handleHttpException` renders as `ERROR: invalid url - <url>`, a
  distinct flavor from the connection-refused message every *transport*
  failure collapses into.
  """
  @spec validate_url(String.t()) :: :ok | {:error, String.t()}
  def validate_url(url) do
    case URI.new(url) do
      {:ok, %URI{host: host, port: port}}
      when is_binary(host) and host != "" and is_integer(port) ->
        :ok

      _invalid ->
        {:error, "ERROR: invalid url - #{url}"}
    end
  end

  @doc "GET `url` and map the outcome to a `%{stdout, stderr, exit}` result."
  @spec check(String.t()) :: Bier.CLI.result()
  def check(url) do
    case validate_url(url) do
      :ok -> request(url)
      {:error, message} -> %{stdout: "", stderr: [message, "\n"], exit: 1}
    end
  end

  defp request(url) do
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
