defmodule Bier.Plugs.FallbackController do
  @moduledoc """
  Renders errors using PostgREST's JSON envelope `{code, message, details, hint}`
  and maps internal error reasons / Postgres `SQLSTATE`s to HTTP statuses and
  `PGRST*` codes.

  New error shapes should be added as additional `call/2` clauses rather than
  handled inline in `ActionController`.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(config), do: config

  @impl Plug
  # ---- embed resolution errors (PGRST200 / PGRST201) ----------------------
  def call(conn, {:error, {:embed_error, %{status: status, body: body}}}) do
    error(conn, status, body)
  end

  # ---- target resolution errors -------------------------------------------
  def call(conn, {:error, {:invalid_schema, schema}}) do
    error(conn, 406, %{
      code: "PGRST106",
      message: "Invalid schema: #{schema}",
      details: nil,
      hint: nil
    })
  end

  def call(conn, {:error, {:unknown_relation, schema, relation}}) do
    error(conn, 404, %{
      code: "PGRST205",
      message: "Could not find the table '#{schema}.#{relation}' in the schema cache",
      details: nil,
      hint: nil
    })
  end

  def call(conn, {:error, :invalid_path}) do
    error(conn, 404, %{
      code: "PGRST125",
      message: "Invalid path specified in request URL",
      details: nil,
      hint: nil
    })
  end

  def call(conn, {:error, :rpc_unsupported}) do
    error(conn, 404, %{
      code: "PGRST202",
      message: "Could not find the function in the schema cache",
      details: nil,
      hint: nil
    })
  end

  # ---- content negotiation: no acceptable media type (406 PGRST107) -------
  def call(conn, {:error, {:not_acceptable, accept}}) do
    error(conn, 406, %{
      code: "PGRST107",
      message: "None of these media types are available: #{accept}",
      details: nil,
      hint: nil
    })
  end

  # ---- singular plurality violation (406 PGRST116) ------------------------
  def call(conn, {:error, {:not_singular, rows}}) do
    error(conn, 406, %{
      code: "PGRST116",
      message: "Cannot coerce the result to a single JSON object",
      details: "The result contains #{rows} rows",
      hint: nil
    })
  end

  # ---- malformed CSV insert body (400 PGRST102) ---------------------------
  def call(conn, {:error, :ragged_csv}) do
    error(conn, 400, %{
      code: "PGRST102",
      message: "All lines must have same number of fields",
      details: nil,
      hint: nil
    })
  end

  def call(conn, {:error, :method_not_allowed}) do
    error(conn, 405, %{
      code: "PGRST117",
      message: "Unsupported HTTP method",
      details: nil,
      hint: nil
    })
  end

  # ---- logic-tree parse error (PGRST100) ----------------------------------
  # An empty logic group (e.g. `or=()`) is a zero-arity error. PostgREST renders
  # the offending logic value wrapped in an extra paren pair and points at the
  # column where it expected a condition. For `or=()` the value is `()`, so the
  # rendered tree is `(())` and the failing column is 4 (len("()") + 2).
  def call(conn, {:error, {:logic_parse, raw}}) do
    column = byte_size(raw) + 2

    error(conn, 400, %{
      code: "PGRST100",
      message: "\"failed to parse logic tree (#{raw})\" (line 1, column #{column})",
      details:
        "unexpected \")\" expecting field name (* or [a..z0..9_$]), negation operator (not) or logic operator (and, or)",
      hint: nil
    })
  end

  # ---- order parse error (PGRST100) ---------------------------------------
  def call(conn, {:error, {:order_parse, term, detail, column}}) do
    error(conn, 400, %{
      code: "PGRST100",
      message: "\"failed to parse order (#{term})\" (line 1, column #{column})",
      details: detail,
      hint: nil
    })
  end

  # ---- related order on a non-to-one relationship (PGRST118) --------------
  def call(conn, {:error, {:related_order_not_to_one, source, target}}) do
    error(conn, 400, %{
      code: "PGRST118",
      message: "A related order on '#{target}' is not possible",
      details: "'#{source}' and '#{target}' do not form a many-to-one or one-to-one relationship",
      hint: nil
    })
  end

  # ---- embedded resource referenced by a filter but not selected (PGRST108)
  def call(conn, {:error, {:embed_not_selected, resource}}) do
    error(conn, 400, %{
      code: "PGRST108",
      message: "'#{resource}' is not an embedded resource in this request",
      details: nil,
      hint: "Verify that '#{resource}' is included in the 'select' query parameter."
    })
  end

  # ---- pagination range errors (416 PGRST103) -----------------------------
  # A negative `limit` query param (NegativeLimit).
  def call(conn, {:error, :negative_limit}) do
    range_not_satisfiable(conn, "Limit should be greater than or equal to zero.")
  end

  # A `Range` header whose lower boundary exceeds the upper boundary
  # (LowerGTUpper / offside).
  def call(conn, {:error, :range_offside}) do
    range_not_satisfiable(
      conn,
      "The lower boundary must be lower than or equal to the upper boundary in the Range header."
    )
  end

  # ---- query parsing errors (PGRST100) ------------------------------------
  def call(conn, {:error, reason})
      when reason in [
             :unprocessable,
             :unprocessable_filter,
             :order_bad_syntax,
             :bad_limit,
             :bad_offset,
             :bad_logic,
             :embed,
             :embed_unsupported
           ] do
    error(conn, 400, %{
      code: "PGRST100",
      message: "\"failed to parse filter\"",
      details: nil,
      hint: nil
    })
  end

  # ---- Postgres errors: SQLSTATE -> HTTP ----------------------------------
  def call(conn, {:error, %Postgrex.Error{postgres: %{} = pg}}) do
    {status, code} = sqlstate_map(pg[:code], pg[:pg_code])

    error(conn, status, %{
      code: code || to_string(pg[:pg_code] || pg[:code] || ""),
      message: pg[:message],
      details: pg[:detail],
      hint: pg[:hint]
    })
  end

  def call(conn, {:error, %Postgrex.Error{} = err}) do
    error(conn, 500, %{
      code: "PGRST",
      message: Exception.message(err),
      details: nil,
      hint: nil
    })
  end

  # ---- legacy shapes (kept) -----------------------------------------------
  def call(conn, :not_found) do
    error(conn, 404, %{
      code: "PGRST205",
      message: "Not found",
      details: nil,
      hint: nil
    })
  end

  def call(conn, {:error, :bad_request}) do
    error(conn, 400, %{code: "PGRST100", message: "Bad Request", details: nil, hint: nil})
  end

  def call(conn, {:error, :mismatch}) do
    error(conn, 400, %{
      code: "PGRST102",
      message: "All object keys must match",
      details: nil,
      hint: nil
    })
  end

  def call(conn, %{code: :insufficient_privilege} = err) do
    error(conn, 403, Map.put(err, :code, "42501"))
  end

  def call(conn, %{code: :foreign_key_violation} = err) do
    error(conn, 409, Map.put(err, :code, "23503"))
  end

  # ---- catch-all -----------------------------------------------------------
  def call(conn, _other) do
    error(conn, 500, %{
      code: "PGRST",
      message: "Internal Server Error",
      details: nil,
      hint: nil
    })
  end

  # SQLSTATE mapping skeleton (PostgREST PgError handling). The atom comes from
  # Postgrex's `:code` field; the raw five-char code from `:pg_code`.
  defp sqlstate_map(code, _pg_code) do
    case code do
      :insufficient_privilege -> {403, nil}
      :foreign_key_violation -> {409, nil}
      :unique_violation -> {409, nil}
      :check_violation -> {400, nil}
      :not_null_violation -> {400, nil}
      :invalid_text_representation -> {400, nil}
      :undefined_table -> {404, "PGRST205"}
      :undefined_column -> {400, nil}
      :undefined_function -> {404, "PGRST202"}
      :raise_exception -> {400, nil}
      _ -> {400, nil}
    end
  end

  defp range_not_satisfiable(conn, details) do
    error(conn, 416, %{
      code: "PGRST103",
      message: "Requested range not satisfiable",
      details: details,
      hint: nil
    })
  end

  defp error(conn, status, body) do
    response = Bier.json_library().encode_to_iodata!(body)

    conn
    |> put_resp_content_type("application/json", "utf-8")
    |> send_resp(status, response)
  end
end
