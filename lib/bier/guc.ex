defmodule Bier.Guc do
  @moduledoc """
  Reads and applies the PostgREST response GUCs a function or trigger may set
  during a request:

    * `response.headers` — a JSON array of single-key objects, each becoming a
      response header. The same name may appear twice (e.g. two `Set-Cookie`),
      so headers are emitted in order and never folded. A malformed value
      (anything but an array of single-key string-valued objects) is `PGRST111`.
    * `response.status` — overrides the HTTP status. A non-integer / out-of-range
      value is `PGRST112`.

  The GUCs are transaction-local (`set_config(..., true)` / `SET LOCAL`), so
  `read/1` must run on the SAME Postgrex transaction connection that executed the
  function/mutation, before the transaction ends.
  """

  import Plug.Conn

  @doc """
  Read the two response GUCs on transaction connection `tx`.

  Returns `{:ok, %{headers: [{name, value}], status: integer | nil}}` or
  `{:error, :bad_response_headers_guc}` / `{:error, :bad_response_status_guc}`.
  """
  def read(tx) do
    %Postgrex.Result{rows: [[headers_raw, status_raw]]} =
      Postgrex.query!(
        tx,
        "SELECT current_setting('response.headers', true), current_setting('response.status', true)",
        []
      )

    with {:ok, headers} <- parse_headers(headers_raw),
         {:ok, status} <- parse_status(status_raw) do
      {:ok, %{headers: headers, status: status}}
    end
  end

  @doc """
  Apply parsed GUC `headers` to `conn`, preserving order and duplicates. The
  status override (`guc.status`) is NOT applied here — the caller must pass it to
  `send_resp` so it takes effect — use `status/2` to fold it with the default.
  """
  def put_headers(conn, %{headers: headers}), do: put_guc_headers(conn, headers)
  def put_headers(conn, _), do: conn

  @doc "The effective status: the GUC override when present, else `default`."
  def status(%{status: status}, _default) when is_integer(status), do: status
  def status(_guc, default), do: default

  # ---- header GUC ----------------------------------------------------------

  defp parse_headers(nil), do: {:ok, []}
  defp parse_headers(""), do: {:ok, []}

  defp parse_headers(raw) do
    case Bier.json_library().decode(raw) do
      {:ok, list} when is_list(list) ->
        collect_header_objects(list, [])

      _ ->
        {:error, :bad_response_headers_guc}
    end
  end

  # Each element must be an object with EXACTLY one key whose value is a string.
  defp collect_header_objects([], acc), do: {:ok, Enum.reverse(acc)}

  defp collect_header_objects([obj | rest], acc) when is_map(obj) do
    case Map.to_list(obj) do
      [{name, value}] when is_binary(name) and is_binary(value) ->
        collect_header_objects(rest, [{name, value} | acc])

      _ ->
        {:error, :bad_response_headers_guc}
    end
  end

  defp collect_header_objects(_other, _acc), do: {:error, :bad_response_headers_guc}

  # Emit each header preserving order/duplicates. `Plug.Conn.put_resp_header/3`
  # replaces an existing header, so a repeatable name (Set-Cookie) that appears
  # more than once is appended as an additional `resp_headers` tuple instead,
  # matching PostgREST which emits two distinct Set-Cookie headers on the wire.
  # (Header values may not contain control chars, so values are never folded
  # with "\n".)
  defp put_guc_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, acc ->
      lname = String.downcase(name)

      if repeatable?(lname) and has_header?(acc, lname) do
        %{acc | resp_headers: acc.resp_headers ++ [{lname, value}]}
      else
        put_resp_header(acc, lname, value)
      end
    end)
  end

  # Headers that legitimately repeat must not be comma-folded (Set-Cookie).
  defp repeatable?("set-cookie"), do: true
  defp repeatable?(_), do: false

  defp has_header?(conn, lname), do: List.keymember?(conn.resp_headers, lname, 0)

  # ---- status GUC ----------------------------------------------------------

  defp parse_status(nil), do: {:ok, nil}
  defp parse_status(""), do: {:ok, nil}

  defp parse_status(raw) do
    case Integer.parse(raw) do
      {code, ""} when code >= 100 and code <= 599 -> {:ok, code}
      _ -> {:error, :bad_response_status_guc}
    end
  end
end
