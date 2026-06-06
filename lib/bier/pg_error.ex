defmodule Bier.PgError do
  @moduledoc """
  Translates a `Postgrex.Error` (a Postgres `ServerError`) into the PostgREST
  HTTP response: status code, JSON error envelope, extra response headers, and
  an optional custom reason phrase.

  This mirrors PostgREST's `pgErrorStatus` (`src/PostgREST/Error.hs`) including
  the two special SQLSTATE families that give a function full control over the
  response:

    * `PTxxx` — the digits after `PT` are the HTTP status (non-numeric ⇒ 500).
    * `PGRST` — the `MESSAGE` is the JSON body envelope and the `DETAIL` is a
      JSON object `{status, status_text, headers}`. A malformed/missing
      `MESSAGE`/`DETAIL` becomes a `PGRST121` parse error.

  The returned shape is `{status, body, headers, status_text}` where `body` is a
  map with string keys `"code" | "message" | "details" | "hint"`, `headers` is a
  list of `{name, value}` extra headers (e.g. the `X-Header` from a `PGRST`
  raise), and `status_text` is `nil` or a custom reason phrase.
  """

  @type result ::
          {status :: pos_integer(), body :: map(), headers :: [{binary(), binary()}],
           status_text :: binary() | nil}

  @msg_parse_hint "MESSAGE must be a JSON object with obligatory keys: 'code', 'message' and optional keys: 'details', 'hint'."
  @det_parse_hint "DETAIL must be a JSON object with obligatory keys: 'status', 'headers' and optional key: 'status_text'."
  @parse_message "Could not parse JSON in the \"RAISE SQLSTATE 'PGRST'\" error"

  @doc """
  Build the `{status, body, headers, status_text}` tuple for a Postgres server
  error. Returns `nil` if the error carries no Postgres `postgres` map (a
  connection/client error), so callers can fall back to a generic 500.
  """
  @spec translate(Postgrex.Error.t()) :: result() | nil
  def translate(%Postgrex.Error{postgres: %{} = pg}) do
    raw = to_string(pg[:pg_code] || pg[:code] || "")
    handle(raw, pg)
  end

  def translate(%Postgrex.Error{}), do: nil

  # ---- PGRST: full response control ----------------------------------------

  defp handle("PGRST", pg) do
    message = pg[:message]
    detail = pg[:detail]

    case parse_pgrst(message, detail) do
      {:ok, msg_json, det_json} ->
        body = %{
          "code" => msg_json["code"],
          "message" => msg_json["message"],
          "details" => Map.get(msg_json, "details"),
          "hint" => Map.get(msg_json, "hint")
        }

        status = pgrst_status(det_json)
        status_text = det_json["status_text"]
        headers = pgrst_headers(det_json)
        {status, body, headers, status_text}

      {:error, details} ->
        hint = pgrst_error_hint(details)

        {500,
         %{
           "code" => "PGRST121",
           "message" => @parse_message,
           "details" => details,
           "hint" => hint
         }, [], nil}
    end
  end

  # ---- PTxxx: custom status from the SQLSTATE digits -----------------------

  defp handle("PT" <> rest, pg) do
    status =
      case Integer.parse(rest) do
        {n, ""} when n >= 100 and n <= 599 -> n
        _ -> 500
      end

    {status, envelope(pg, "PT" <> rest), [], nil}
  end

  # ---- generic SQLSTATE -> HTTP --------------------------------------------

  defp handle(code, pg) do
    {status_for(code, pg[:message]), envelope(pg, code), [], nil}
  end

  # PostgREST pgErrorStatus (Error.hs). `m` is the server message (used by the
  # cardinality_violation / invalid_parameter_value special cases).
  defp status_for(code, m) do
    cond do
      prefix?(code, "08") -> 503
      prefix?(code, "09") -> 500
      prefix?(code, "0L") -> 403
      prefix?(code, "0P") -> 403
      code == "23503" -> 409
      code == "23505" -> 409
      code == "25006" -> 405
      code == "21000" -> if suffix?(m, "requires a WHERE clause"), do: 400, else: 500
      code == "22023" -> invalid_parameter_value_status(m)
      prefix?(code, "25") -> 500
      prefix?(code, "28") -> 403
      prefix?(code, "2D") -> 500
      prefix?(code, "38") -> 500
      prefix?(code, "39") -> 500
      prefix?(code, "3B") -> 500
      prefix?(code, "40") -> 500
      code == "53400" -> 500
      prefix?(code, "53") -> 503
      prefix?(code, "54") -> 500
      prefix?(code, "55") -> 500
      code == "57P01" -> 503
      prefix?(code, "57") -> 500
      prefix?(code, "58") -> 500
      prefix?(code, "F0") -> 500
      prefix?(code, "HV") -> 500
      code == "P0001" -> 400
      prefix?(code, "P0") -> 500
      prefix?(code, "XX") -> 500
      code == "42883" -> if prefix?(m, "function xmlagg("), do: 406, else: 404
      code == "42P01" -> 404
      code == "42P17" -> 500
      code == "42501" -> 403
      true -> 400
    end
  end

  defp invalid_parameter_value_status(m) do
    if prefix?(m, "role") and suffix?(m, "does not exist"), do: 401, else: 400
  end

  # ---- helpers -------------------------------------------------------------

  defp envelope(pg, code) do
    %{
      "code" => code,
      "message" => pg[:message],
      "details" => pg[:detail],
      "hint" => pg[:hint]
    }
  end

  defp prefix?(nil, _p), do: false
  defp prefix?(s, p), do: String.starts_with?(s, p)

  defp suffix?(nil, _s), do: false
  defp suffix?(s, suf), do: String.ends_with?(s, suf)

  # PostgREST: status defaults to 500 if absent; getStatus reads the "status" key.
  defp pgrst_status(det_json) do
    case det_json["status"] do
      n when is_integer(n) -> n
      _ -> 500
    end
  end

  defp pgrst_headers(det_json) do
    case det_json["headers"] do
      %{} = hs -> for {k, v} <- hs, do: {to_string(k), to_string(v)}
      _ -> []
    end
  end

  # parseRaisePGRST: MESSAGE must decode to a JSON object; DETAIL must be present
  # and decode to a JSON object. The first failure (MESSAGE, then missing
  # DETAIL, then DETAIL) produces the PGRST121 `details` string.
  defp parse_pgrst(message, detail) do
    with {:ok, msg_json} <- decode_object(message, {:message, message}),
         {:ok, raw_detail} <- detail_present(detail),
         {:ok, det_json} <- decode_object(raw_detail, {:detail, raw_detail}) do
      {:ok, msg_json, det_json}
    end
  end

  defp detail_present(nil), do: {:error, "DETAIL is missing in the RAISE statement"}
  defp detail_present(detail), do: {:ok, detail}

  defp decode_object(raw, on_error) do
    case Bier.json_library().decode(raw || "") do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, error_detail(on_error)}
    end
  end

  defp error_detail({:message, raw}), do: "Invalid JSON value for MESSAGE: '#{raw}'"
  defp error_detail({:detail, raw}), do: "Invalid JSON value for DETAIL: '#{raw}'"

  # The hint depends on which clause failed: a missing/invalid DETAIL points at
  # the DETAIL shape, an invalid MESSAGE points at the MESSAGE shape.
  defp pgrst_error_hint("DETAIL is missing in the RAISE statement"), do: @det_parse_hint
  defp pgrst_error_hint("Invalid JSON value for DETAIL:" <> _), do: @det_parse_hint
  defp pgrst_error_hint(_), do: @msg_parse_hint
end
