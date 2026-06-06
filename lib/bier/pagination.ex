defmodule Bier.Pagination do
  @moduledoc """
  Pagination semantics for the read pipeline: the `Range`/`Range-Unit` request
  headers, the `Prefer: count=` modes, and the resulting `Content-Range`
  response header and HTTP status (200/206/416).

  PostgREST resolves an effective `{offset, limit}` window from either the
  `limit`/`offset` query parameters or a `Range` header (the header wins when
  present), requests a row count according to `Prefer: count=`, then renders a
  `Content-Range` of `<first>-<last>/<total>` (or `*/<total>` for an empty
  window) and picks the status from whether the window covers the whole set.
  """

  import Plug.Conn, only: [get_req_header: 2]

  @type count_mode :: :none | :exact | :planned | :estimated

  @doc """
  Resolve the count mode from a `Prefer: count=<mode>` header. Defaults to
  `:none` (PostgREST's default; total is rendered as `*`).
  """
  @spec count_mode(Plug.Conn.t()) :: count_mode()
  def count_mode(conn) do
    conn
    |> prefer_values()
    |> Enum.find_value(:none, fn v ->
      case v do
        "count=exact" -> :exact
        "count=planned" -> :planned
        "count=estimated" -> :estimated
        "count=none" -> :none
        _ -> false
      end
    end)
  end

  defp prefer_values(conn) do
    conn
    |> get_req_header("prefer")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
  end

  @doc """
  Parse the `Range` header (when `Range-Unit` is `items`/absent) into
  `{:ok, {offset, limit}}`, where `limit` is `nil` for an open-ended range.

  Returns:
    * `{:ok, nil}` when no usable Range header is present (keep query params),
    * `{:ok, {offset, limit}}` for a valid range,
    * `{:error, :range_offside}` when the lower bound exceeds the upper bound.
  """
  @spec range_window(Plug.Conn.t()) ::
          {:ok, nil | {non_neg_integer(), non_neg_integer() | nil}} | {:error, :range_offside}
  def range_window(conn) do
    unit =
      case get_req_header(conn, "range-unit") do
        [u | _] -> String.trim(u)
        [] -> "items"
      end

    case get_req_header(conn, "range") do
      [raw | _] when unit in ["items", ""] -> parse_range(String.trim(raw))
      _ -> {:ok, nil}
    end
  end

  # `from-to` (closed), `from-` (open-ended). A `from-to` with to < from is the
  # "offside" error (RangeSpec offside_invalid). The limit is `to - from + 1`.
  defp parse_range(raw) do
    case String.split(raw, "-", parts: 2) do
      [from_s, ""] ->
        with {:ok, from} <- non_neg_int(from_s), do: {:ok, {from, nil}}

      [from_s, to_s] ->
        with {:ok, from} <- non_neg_int(from_s),
             {:ok, to} <- non_neg_int(to_s) do
          if to < from, do: {:error, :range_offside}, else: {:ok, {from, to - from + 1}}
        end

      _ ->
        {:ok, nil}
    end
  end

  defp non_neg_int(s) do
    case Integer.parse(s) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, :range_offside}
    end
  end

  @doc """
  Render the `Content-Range` header value.

    * `offset` — the effective offset (lower bound) of the window.
    * `rows`   — number of rows actually returned.
    * `total`  — the total count (integer) when known, or `nil` for `*`.
  """
  @spec content_range(non_neg_integer(), non_neg_integer(), non_neg_integer() | nil) :: String.t()
  def content_range(offset, rows, total) do
    total_str = if is_integer(total), do: Integer.to_string(total), else: "*"

    if rows == 0 do
      "*/#{total_str}"
    else
      "#{offset}-#{offset + rows - 1}/#{total_str}"
    end
  end

  @doc """
  HTTP status for a successful read given the window and (optional) total.

  Returns 206 when a count is known and the returned window does not cover the
  whole set (a non-zero offset, or fewer rows than the total). Otherwise 200.
  """
  @spec status(non_neg_integer(), non_neg_integer(), non_neg_integer() | nil) :: 200 | 206
  def status(_offset, _rows, nil), do: 200

  def status(offset, rows, total) when is_integer(total) do
    cond do
      rows == 0 -> 200
      offset > 0 -> 206
      offset + rows < total -> 206
      true -> 200
    end
  end

  @doc """
  Whether a requested window is out of bounds: a non-zero offset that lands at
  or past the last row, with a known total and no rows returned. PostgREST
  renders this as 416 PGRST103 (OutOfBounds) — but only when a count is known
  (i.e. `Prefer: count=` was honored).
  """
  @spec out_of_bounds?(non_neg_integer(), non_neg_integer(), non_neg_integer() | nil) :: boolean()
  def out_of_bounds?(offset, rows, total)
      when is_integer(total) and offset > 0 and rows == 0 and offset >= total,
      do: true

  def out_of_bounds?(_offset, _rows, _total), do: false
end
