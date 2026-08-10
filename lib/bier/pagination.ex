defmodule Bier.Pagination do
  @moduledoc """
  Pagination semantics for the read pipeline: the `Range`/`Range-Unit` request
  headers, the `Prefer: count=` modes, and the resulting `Content-Range`
  response header and HTTP status (200/206/416).

  PostgREST resolves an effective `{offset, limit}` window by INTERSECTING the
  window the `limit`/`offset` query parameters describe with the one the `Range`
  header describes (`headerAndLimitRange = rangeIntersection headerRange
  limitRange`, `ApiRequest.hs#L185`), requests a row count according to
  `Prefer: count=`, then renders a `Content-Range` of `<first>-<last>/<total>`
  (or `*/<total>` for an empty window) and picks the status from whether the
  window covers the whole set.

  The `Range` REQUEST header is read for `GET` only — `headerRange = if method
  == "GET" then rangeRequested hdrs else allRange` (`ApiRequest.hs#L183`, under a
  comment citing RFC 9110's "the Range header must be ignored for all methods
  other than GET"). `method` there is the raw request method, so `HEAD` is not
  folded into `GET` and a `POST /rpc/<fn>` ignores the header too.
  """

  import Plug.Conn, only: [get_req_header: 2]

  @type count_mode :: Bier.Preferences.count_mode()

  @doc """
  Resolve the count mode from a `Prefer: count=<mode>` header. Defaults to
  `:none` (PostgREST's default; total is rendered as `*`).

  `Bier.Preferences` owns the `Prefer` vocabulary — which `count=` tokens exist
  and which are invalid — and this module only consumes the resolved mode. That
  single ownership is what keeps `count=none` consistent: it is NOT a
  `PreferCount` value, so it resolves to the default `:none` here *because it is
  unrecognized*, while `Bier.Preferences` simultaneously reports it in
  `invalidPrefs` (a `handling=strict` request carrying it is a 400 PGRST122).
  """
  @spec count_mode(Plug.Conn.t()) :: count_mode()
  defdelegate count_mode(conn), to: Bier.Preferences

  @doc """
  The count mode a function call (`/rpc/<fn>`) actually honors.

  A function call plans as a `CallReadPlan`, whose query is built with `mempty`
  in the explain-query position (`Query.hs#L54`) — unlike the table/view branch
  at `Query.hs#L50` there is no EXPLAIN result to substitute — and whose
  `MainTx.hs#L161` clause returns the result set without rewriting the table
  total. `shouldCount PlannedCount` is `False`, so the counting CTE is skipped
  too and the SQL total stays `null::bigint`. `Prefer: count=planned` therefore
  has no effect at all on an RPC: the total stays `*` and the status stays 200.
  `count=exact`/`count=estimated` do run the counting CTE and still yield a
  total.
  """
  @spec call_count_mode(Plug.Conn.t()) :: count_mode()
  def call_count_mode(conn) do
    case count_mode(conn) do
      :planned -> :none
      mode -> mode
    end
  end

  @typedoc """
  A row window as PostgREST's `NonnegRange`: the inclusive lower and upper row
  indexes, with `nil` for an unbounded upper end.
  """
  @type bounds :: {non_neg_integer(), non_neg_integer() | nil}

  @typedoc """
  A `NonnegRange`: `nil` is `allRange` (unconstrained), `:empty` is
  `emptyRange`, anything else a concrete `t:bounds/0` pair. A pair whose upper
  bound falls below its lower bound is empty too — `ranged-sets` defines
  `rangeIsEmpty (Range lower upper) = upper <= lower` and makes every empty
  range `Eq`-equal, which is why emptiness is a semantic test here rather than a
  structural one.
  """
  @type range :: nil | :empty | bounds()

  @doc """
  Parse the `Range` header (when `Range-Unit` is `items`/absent) into the
  `t:range/0` it denotes.

  The header is honored for `GET` only; every other method (including `HEAD` and
  a `POST /rpc/<fn>`) reads as "no Range header" (`allRange`).
  """
  @spec range_window(Plug.Conn.t()) :: range()
  def range_window(%Plug.Conn{method: method}) when method != "GET", do: nil

  def range_window(conn) do
    unit =
      case get_req_header(conn, "range-unit") do
        [u | _] -> String.trim(u)
        [] -> "items"
      end

    case get_req_header(conn, "range") do
      [raw | _] when unit in ["items", ""] -> parse_range(String.trim(raw))
      _ -> nil
    end
  end

  # `rangeParse` (RangeQuery.hs): the value must match `^([0-9]+)-([0-9]*)$` or
  # the header is ignored entirely (`allRange`). The LOWER group is REQUIRED —
  # a bare `-`, a suffix range like `-5` and any non-numeric bound all fail the
  # pattern and leave the full range in force, they do NOT describe an empty
  # window. Only the upper group may be absent, leaving the range open
  # (`maybe allRange rangeLeq`); a `from-to` with `to < from` is empty (the
  # "offside" shape).
  defp parse_range(raw) do
    case String.split(raw, "-", parts: 2) do
      [from_s, to_s] -> bounds(digits(from_s), digits(to_s))
      _ -> nil
    end
  end

  defp bounds(:error, _to), do: nil
  defp bounds(_from, :error), do: nil
  # An absent lower bound fails `[0-9]+`, so the whole header is ignored.
  defp bounds(nil, _to), do: nil
  defp bounds(from, nil), do: {from, nil}
  defp bounds(from, to) when to < from, do: :empty
  defp bounds(from, to), do: {from, to}

  # One `[0-9]*` group: absent (`nil`), its value, or `:error` when the whole
  # header fails the pattern.
  defp digits(""), do: nil

  defp digits(s) do
    case Integer.parse(s) do
      {n, ""} when n >= 0 -> n
      _ -> :error
    end
  end

  @doc """
  Apply the `Range` header and the `db-max-rows` cap to a parsed plan.

  The `Range` header window is INTERSECTED with the window the `limit`/`offset`
  query parameters describe — it does not override them. `?limit=2` describes
  rows `0..1`, so `Range: 0-5` still yields two rows; conversely `?limit=3` with
  `Range: 0-1` yields two. `max_rows` (PostgREST `db-max-rows`, `nil` for
  uncapped) then bounds the effective limit.

  The intersection is the top-level range, and `isInvalidRange = topLevelRange
  == emptyRange && not (hasLimitZero limitRange)` (`ApiRequest.hs#L190`) rejects
  it with 416 PGRST103 whenever it came out EMPTY — no matter which input
  emptied it. `?offset=3` with `Range: 0-1` intersects to nothing and is a 416,
  not an empty 200. `?limit=0` is the sole exception: it is rewritten to the
  `limitZeroRange` sentinel upstream and answers 200 with zero rows.

  Returns `{:ok, plan}` or `{:error, {:invalid_range, reason}}`, where `reason`
  picks the details string exactly as `InvalidRange (if rangeIsEmpty headerRange
  then LowerGTUpper else NegativeLimit)` does (`ApiRequest.hs#L177`) — on the
  emptiness of the RANGE HEADER, not of whichever input emptied the result.
  """
  @spec apply_window(map(), Plug.Conn.t(), pos_integer() | nil) ::
          {:ok, map()} | {:error, {:invalid_range, :lower_gt_upper | :negative_limit}}
  def apply_window(plan, conn, max_rows) do
    header = range_window(conn)
    top_level = intersect(header, param_window(plan))

    cond do
      empty?(top_level) and not limit_zero?(plan) ->
        {:error, {:invalid_range, invalid_range_reason(header)}}

      is_nil(header) ->
        {:ok, apply_max_rows(plan, max_rows)}

      true ->
        {:ok, plan |> put_window(top_level) |> apply_max_rows(max_rows)}
    end
  end

  # The window the `limit`/`offset` query params describe, as the same
  # `{lower, upper}` pair a Range header parses to (`nil` upper = open-ended).
  # `?limit=l&offset=o` is rows `o .. o+l-1` (QueryParams.hs#L181, #L187).
  defp param_window(plan) do
    offset = plan[:offset] || 0

    case plan[:limit] do
      nil -> {offset, nil}
      limit -> {offset, offset + limit - 1}
    end
  end

  # `rangeIntersection headerRange limitRange`: the greatest lower bound and the
  # least upper bound. The header side is a full `t:range/0` — `allRange`
  # (`nil`) is the identity and an already-empty header keeps the result empty —
  # while the limit/offset side is always concrete bounds.
  defp intersect(nil, params), do: params
  defp intersect(:empty, _params), do: :empty
  defp intersect({lo1, up1}, {lo2, up2}), do: {max(lo1, lo2), least_upper(up1, up2)}

  defp least_upper(nil, up), do: up
  defp least_upper(up, nil), do: up
  defp least_upper(up1, up2), do: min(up1, up2)

  defp empty?(:empty), do: true
  defp empty?(nil), do: false
  defp empty?({_lower, nil}), do: false
  defp empty?({lower, upper}), do: upper < lower

  # `hasLimitZero r = rangeUpper r == rangeUpper limitZeroRange`: the exception
  # tests the limit window's UPPER BOUNDARY against -1, not the range as a
  # whole. It cannot be range equality: ranged-sets compares any two empty
  # ranges equal, and `?limit=-1` (window 0..-2) is empty yet the spec says it
  # IS rejected — only the upper boundary tells 0..-1 and 0..-2 apart.
  #
  # Since the window is `offset .. offset + limit - 1`, the exception holds
  # exactly when `offset + limit - 1 == -1`, i.e. `?limit=0` at offset 0 (case
  # 1253). `?limit=0&offset=5` has upper 4 and is therefore rejected like any
  # other empty range.
  defp limit_zero?(plan) do
    case plan[:limit] do
      nil -> false
      limit -> (plan[:offset] || 0) + limit - 1 == -1
    end
  end

  defp invalid_range_reason(header) do
    if empty?(header), do: :lower_gt_upper, else: :negative_limit
  end

  # An empty window that survived the `limit=0` exception returns no rows from
  # the requested offset.
  defp put_window(plan, :empty), do: %{plan | limit: 0}

  defp put_window(plan, {lower, nil}), do: %{plan | offset: lower, limit: nil}

  defp put_window(plan, {lower, upper}),
    do: %{plan | offset: lower, limit: max(upper - lower + 1, 0)}

  defp apply_max_rows(plan, nil), do: plan
  defp apply_max_rows(%{limit: nil} = plan, max_rows), do: %{plan | limit: max_rows}

  defp apply_max_rows(%{limit: limit} = plan, max_rows),
    do: %{plan | limit: min(limit, max_rows)}

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
