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
  def call(conn, {:error, {:invalid_schema, schema, exposed}}) do
    error(conn, 406, %{
      code: "PGRST106",
      message: "Invalid schema: #{schema}",
      details: nil,
      hint: invalid_schema_hint(exposed)
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

  def call(conn, {:error, :openapi_disabled}) do
    error(conn, 404, %{
      code: "PGRST126",
      message: "Root endpoint metadata is disabled",
      details: nil,
      hint: nil
    })
  end

  # A fully-built PGRST202 not-found envelope (with hint/details) from the RPC
  # resolver.
  def call(conn, {:error, {:rpc_not_found, body}}) do
    error(conn, 404, body)
  end

  # PATCH/PUT/DELETE on /rpc/<fn> is unsupported (PGRST101, 405).
  def call(conn, {:error, {:rpc_invalid_method, method}}) do
    error(conn, 405, %{
      code: "PGRST101",
      message: "Cannot use the #{method} method on RPC",
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

  # ---- mutation body parse errors (400 PGRST102) --------------------------
  def call(conn, {:error, :invalid_json}) do
    error(conn, 400, %{
      code: "PGRST102",
      message: "Empty or invalid json",
      details: nil,
      hint: nil
    })
  end

  def call(conn, {:error, :non_uniform}) do
    error(conn, 400, %{
      code: "PGRST102",
      message: "All object keys must match",
      details: nil,
      hint: nil
    })
  end

  # ---- columns param errors -----------------------------------------------
  # A blank `?columns=` is a PGRST100 parse error.
  def call(conn, {:error, :blank_columns}) do
    error(conn, 400, %{
      code: "PGRST100",
      message: "\"failed to parse columns parameter\"",
      details: nil,
      hint: nil
    })
  end

  # A `?columns=` (or payload key) referencing a column absent from the relation.
  def call(conn, {:error, {:unknown_column, column, relation}}) do
    error(conn, 400, %{
      code: "PGRST204",
      message: "Could not find the '#{column}' column of '#{relation}' in the schema cache",
      details: nil,
      hint: nil
    })
  end

  # ---- PUT upsert errors ---------------------------------------------------
  # limit/offset on PUT (PGRST114).
  def call(conn, {:error, :put_limit_offset}) do
    error(conn, 400, %{
      code: "PGRST114",
      message: "limit/offset querystring parameters are not allowed for PUT",
      details: nil,
      hint: nil
    })
  end

  # PUT filter is not exactly the PK columns with `eq` (PGRST105, 405).
  def call(conn, {:error, :put_pk_filter}) do
    error(conn, 405, %{
      code: "PGRST105",
      message: "Filters must include all and only primary key columns with 'eq' operators",
      details: nil,
      hint: nil
    })
  end

  # PUT payload PK differs from the URL PK (PGRST115).
  def call(conn, {:error, :put_pk_mismatch}) do
    error(conn, 400, %{
      code: "PGRST115",
      message: "Payload values do not match URL in primary key column(s)",
      details: nil,
      hint: nil
    })
  end

  # ---- invalid Prefer with handling=strict (400 PGRST122) -----------------
  def call(conn, {:error, {:invalid_prefs, details}}) do
    error(conn, 400, %{
      code: "PGRST122",
      message: "Invalid preferences given with handling=strict",
      details: details,
      hint: nil
    })
  end

  # ---- response.headers GUC malformed (500 PGRST111) ----------------------
  def call(conn, {:error, :bad_response_headers_guc}) do
    error(conn, 500, %{
      code: "PGRST111",
      message:
        "response.headers guc must be a JSON array composed of objects with a single key and a string value",
      details: nil,
      hint: nil
    })
  end

  # ---- response.status GUC invalid (500 PGRST112) -------------------------
  def call(conn, {:error, :bad_response_status_guc}) do
    error(conn, 500, %{
      code: "PGRST112",
      message: "response.status guc must be a valid status code",
      details: nil,
      hint: nil
    })
  end

  # ---- max-affected exceeded (400 PGRST124) -------------------------------
  def call(conn, {:error, {:max_affected, rows}}) do
    error(conn, 400, %{
      code: "PGRST124",
      message: "Query result exceeds max-affected preference constraint",
      details: "The query affects #{rows} rows",
      hint: nil
    })
  end

  # A request presents a JWT but the server has no secret configured to verify
  # it (PostgREST returns 500). Drives the log-level=error access-log case.
  def call(conn, {:error, :jwt_unconfigured}) do
    error(conn, 500, %{
      code: "PGRST301",
      message: "Server lacks JWT secret",
      details: nil,
      hint: nil
    })
  end

  # ---- JWT verification failures (Bier.Auth / Bier.JWT) -------------------
  # No JWT secret configured but a token was presented -> 500 PGRST300.
  def call(conn, {:error, {:jwt, :no_secret}}) do
    error(conn, 500, %{
      code: "PGRST300",
      message: "Server lacks JWT secret",
      details: nil,
      hint: nil
    })
  end

  # Anonymous access disabled (no db-anon-role) and no valid token -> 401 PGRST302.
  def call(conn, {:error, {:jwt, :anon_disabled}}) do
    error(
      conn,
      401,
      %{code: "PGRST302", message: "Anonymous access is disabled", details: nil, hint: nil},
      headers: [{"WWW-Authenticate", "Bearer"}]
    )
  end

  # Empty bearer token -> 401 PGRST301.
  def call(conn, {:error, {:jwt, :empty}}) do
    msg = "Empty JWT is sent in Authorization header"
    jwt_error(conn, "PGRST301", msg)
  end

  # Wrong number of JWT segments -> 401 PGRST301.
  def call(conn, {:error, {:jwt, {:parts, n}}}) do
    jwt_error(conn, "PGRST301", "Expected 3 parts in JWT; got #{n}")
  end

  # Expired token -> 401 PGRST303.
  def call(conn, {:error, {:jwt, :expired}}) do
    jwt_error(conn, "PGRST303", "JWT expired")
  end

  # Any other JWT failure (bad signature/json/claims/audience) -> 401 PGRST301.
  def call(conn, {:error, {:jwt, _reason}}) do
    jwt_error(conn, "PGRST301", "JWSError JWSInvalidSignature")
  end

  # A 42501 (or EXECUTE-denied) under the anonymous role surfaces as 401 with
  # WWW-Authenticate: Bearer (vs 403 for an authenticated role).
  def call(conn, {:error, {:auth_denied, %Postgrex.Error{postgres: pg}}}) do
    error(
      conn,
      401,
      %{
        "code" => "42501",
        "message" => pg[:message],
        "details" => pg[:detail],
        "hint" => pg[:hint]
      },
      headers: [{"WWW-Authenticate", "Bearer"}]
    )
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

  # ---- select parse error (PGRST100) --------------------------------------
  def call(conn, {:error, {:select_parse, select, detail, column}}) do
    error(conn, 400, %{
      code: "PGRST100",
      message: "\"failed to parse select parameter (#{select})\" (line 1, column #{column})",
      details: detail,
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
  # Full PostgREST `pgErrorStatus` mapping (incl. `PTxxx`/`PGRST` raises) lives
  # in `Bier.PgError`. A connection/client error (no `postgres` map) ⇒ 500.
  def call(conn, {:error, %Postgrex.Error{} = err}) do
    case Bier.PgError.translate(err) do
      # `status_text` (a custom HTTP reason phrase from a `PGRST` raise) is
      # carried by `PgError` but not emitted here: Bandit derives the reason
      # phrase from `Plug.Conn.Status` (configured in config/config.exs), and
      # Plug offers no per-response override. The conformance cases that assert
      # a custom reason phrase are tagged `:pending` (`status_text`).
      {status, body, headers, _status_text} ->
        error(conn, status, body, headers: headers)

      nil ->
        error(conn, 500, %{
          code: "PGRST",
          message: Exception.message(err),
          details: nil,
          hint: nil
        })
    end
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

  # PGRST106 hint listing the exposed (profile-selectable) schemas in exposure
  # order, comma-separated and verbatim (special characters are not escaped).
  defp invalid_schema_hint(nil), do: nil
  defp invalid_schema_hint([]), do: nil

  defp invalid_schema_hint(schemas) when is_list(schemas),
    do: "Only the following schemas are exposed: " <> Enum.join(schemas, ", ")

  # PGRST301/PGRST303 carry a `WWW-Authenticate: Bearer error="invalid_token",
  # error_description="<message>"` header (PostgREST Auth error rendering).
  defp jwt_error(conn, code, message) do
    www = ~s(Bearer error="invalid_token", error_description="#{message}")

    error(
      conn,
      401,
      %{code: code, message: message, details: nil, hint: nil},
      headers: [{"WWW-Authenticate", www}]
    )
  end

  defp range_not_satisfiable(conn, details) do
    error(conn, 416, %{
      code: "PGRST103",
      message: "Requested range not satisfiable",
      details: details,
      hint: nil
    })
  end

  defp error(conn, status, body, opts \\ []) do
    response = Bier.json_library().encode_to_iodata!(body) |> IO.iodata_to_binary()
    code = body_code(body)

    conn
    |> put_resp_content_type("application/json", "utf-8")
    |> put_resp_header("content-length", Integer.to_string(byte_size(response)))
    |> maybe_proxy_status(code)
    |> put_extra_headers(Keyword.get(opts, :headers, []))
    |> send_resp(status, response)
  end

  # Every PostgREST-originated error carries `Proxy-Status: PostgREST; error=<code>`
  # (Error.hs proxyStatusHeader). The code is the error envelope's `code`.
  defp maybe_proxy_status(conn, nil), do: conn

  defp maybe_proxy_status(conn, code),
    do: put_resp_header(conn, "proxy-status", "PostgREST; error=#{code}")

  defp put_extra_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, acc ->
      put_resp_header(acc, String.downcase(to_string(name)), to_string(value))
    end)
  end

  defp body_code(%{code: code}), do: code
  defp body_code(%{"code" => code}), do: code
  defp body_code(_), do: nil
end
