defmodule Bier.Auth do
  @moduledoc """
  Per-request authentication context: JWT verification, role resolution, and the
  PostgREST request GUCs.

  PostgREST runs every request inside a transaction that first establishes the
  authenticated role and a set of `request.*` settings, then runs the main query.
  Concretely, before the query it executes (transaction-local):

    * `SET LOCAL ROLE <role>` — the JWT `role` claim, else `db-anon-role`;
    * `set_config('request.jwt.claims', <claims-json>, true)`;
    * `set_config('request.method', <method>, true)`;
    * `set_config('request.path', <path>, true)`;
    * `set_config('request.headers', <json of lowercased headers>, true)`;
    * `set_config('request.cookies', <json of cookie pairs>, true)`;
    * one `set_config('app.settings.<name>', <value>, true)` per configured
      `app_settings` entry (PostgREST app.settings.*);
    * the `db-pre-request` proc (if configured), which may itself `SET ROLE` or
      `RAISE` to abort the request.

  SQL functions then read these via `current_setting('request.…')`.

  Bier applies this context whenever auth is configured for the instance
  (`jwt_secret` or `db_anon_role`), for every exposed schema — matching
  PostgREST. When neither is set, requests run as the connecting role with no
  role switch or GUCs. `applicable?/1` encodes that gate.
  """

  alias Bier.JWT

  @type t :: %{
          role: String.t() | nil,
          anonymous?: boolean(),
          claims_json: String.t(),
          method: String.t(),
          path: String.t(),
          headers_json: String.t(),
          cookies_json: String.t()
        }

  @doc """
  True when the per-request auth context (role switch + request GUCs +
  pre-request hook) should be applied — i.e. when auth is configured
  (`jwt_secret` or `db_anon_role`). Mirrors PostgREST, where the authenticator
  connects and every request assumes a role whenever auth is set up.
  """
  @spec applicable?(Bier.Config.t()) :: boolean()
  def applicable?(config), do: config.jwt_secret != nil or config.db_anon_role != nil

  @doc """
  Resolve the auth context for a request, verifying the JWT.

  Returns `{:ok, context}` or `{:error, reason}` where `reason` is a JWT failure
  surfaced by `Bier.Plugs.FallbackController`.
  """
  @spec resolve(Plug.Conn.t(), Bier.Config.t()) :: {:ok, t()} | {:error, term()}
  def resolve(conn, config) do
    token = bearer_token(conn)

    case JWT.verify(token, config.jwt_secret, config.jwt_aud, config.jwt_role_claim_path) do
      {:ok, :anonymous} ->
        build_context(conn, config, nil, anon_claims(config), true)

      {:ok, %{role: role, claims_json: claims_json}} ->
        build_context(conn, config, role, claims_json, false)

      {:error, reason} ->
        {:error, {:jwt, reason}}
    end
  end

  defp build_context(conn, config, role, claims_json, token_anonymous?) do
    resolved_role = role || config.db_anon_role
    # A request is "anonymous" for error surfacing when it carried no usable role
    # (anon role assumed). 42501/EXECUTE-denied then surfaces as 401, vs 403 for
    # an authenticated role.
    anonymous? = token_anonymous? or is_nil(role)

    if is_nil(resolved_role) do
      # Anonymous request with anon role disabled -> PGRST302 (401).
      {:error, {:jwt, :anon_disabled}}
    else
      {:ok,
       %{
         role: resolved_role,
         anonymous?: anonymous?,
         claims_json: claims_json,
         method: conn.method,
         path: conn.request_path,
         headers_json: headers_json(conn),
         cookies_json: cookies_json(conn)
       }}
    end
  end

  @doc """
  Map a `Postgrex.Error` raised under the auth context to the error shape the
  fallback controller expects. A `42501` (insufficient privilege) on an
  anonymous request becomes a 401 with `WWW-Authenticate: Bearer`; on an
  authenticated role it stays a 403 (no header). Other errors pass through.
  """
  @spec map_error(t() | nil, term()) :: term()
  def map_error(%{anonymous?: true}, %Postgrex.Error{postgres: %{code: code}} = err)
      when code in [:insufficient_privilege] do
    {:error, {:auth_denied, err}}
  end

  def map_error(_context, err), do: {:error, err}

  # An authenticated (or anon) request carries the anon role in
  # request.jwt.claims.role when no token set one (case 1480).
  defp anon_claims(%{db_anon_role: nil}), do: "{}"

  defp anon_claims(%{db_anon_role: role}) do
    Bier.json_library().encode!(%{"role" => role})
  end

  @doc """
  Run `fun` (a 1-arity function receiving the transaction connection) inside a
  transaction that first applies the auth context and the optional pre-request
  hook. Returns the function's result (passed through `Postgrex.transaction/2`
  semantics) or an `{:error, …}` from the setup.

  The caller is responsible for ending the transaction (commit/rollback) inside
  `fun`, matching the existing read/mutation/rpc execution code.
  """
  @spec with_context(term(), t(), Bier.Config.t(), (term() -> any())) ::
          {:ok, any()} | {:error, term()}
  def with_context(tx, context, config, fun) do
    apply_context(tx, context)
    apply_app_settings(tx, config)
    run_pre_request(tx, config)
    fun.(tx)
  end

  # Configured app.settings.* values become transaction-local GUCs readable
  # via current_setting('app.settings.<name>'), set in sorted order for
  # determinism.
  defp apply_app_settings(tx, %{app_settings: settings}) do
    settings
    |> Enum.sort()
    |> Enum.each(fn {name, value} -> set_guc(tx, "app.settings." <> name, value) end)
  end

  # Apply the role + request GUCs on the transaction connection. SET LOCAL ROLE
  # uses a validated identifier (the role comes from config or a verified JWT
  # claim; we still quote it). All GUCs are set via parameterized set_config so
  # values are never interpolated. A failure rolls the transaction back so it
  # surfaces as a `{:error, %Postgrex.Error{}}`.
  defp apply_context(tx, context) do
    run!(tx, ~s(SET LOCAL ROLE #{quote_ident(context.role)}), [])

    set_guc(tx, "request.jwt.claims", context.claims_json)
    set_guc(tx, "request.method", context.method)
    set_guc(tx, "request.path", context.path)
    set_guc(tx, "request.headers", context.headers_json)
    set_guc(tx, "request.cookies", context.cookies_json)
  end

  defp set_guc(tx, name, value) do
    run!(tx, "SELECT set_config($1, $2, true)", [name, value])
  end

  # The db-pre-request proc runs after role/GUC setup and before the main query.
  # It may SET LOCAL ROLE (switch_role) or RAISE; a RAISE rolls the transaction
  # back and propagates as a Postgres error (e.g. P0001/400).
  defp run_pre_request(_tx, %{db_pre_request: nil}), do: :ok

  defp run_pre_request(tx, %{db_pre_request: proc}) do
    run!(tx, "SELECT #{qualify(proc)}()", [])
  end

  # Run a setup statement, rolling the transaction back (so the outer
  # transaction returns `{:error, …}`) on failure instead of raising.
  defp run!(tx, sql, params) do
    case Postgrex.query(tx, sql, params) do
      {:ok, _result} -> :ok
      {:error, reason} -> Postgrex.rollback(tx, reason)
    end
  end

  # `schema.proc` -> `"schema"."proc"`; an unqualified name is quoted as-is.
  defp qualify(proc) do
    case String.split(proc, ".", parts: 2) do
      [schema, name] -> "#{quote_ident(schema)}.#{quote_ident(name)}"
      [name] -> quote_ident(name)
    end
  end

  defp quote_ident(ident), do: "\"" <> String.replace(ident, "\"", "\"\"") <> "\""

  # ---- request inputs -----------------------------------------------------

  @doc "Extract the bearer token (scheme-insensitive) from Authorization, or nil."
  def bearer_token(conn) do
    with [value | _] <- Plug.Conn.get_req_header(conn, "authorization"),
         [scheme, token] <- String.split(value, " ", parts: 2),
         "bearer" <- String.downcase(scheme) do
      token
    else
      _ -> nil
    end
  end

  # The request.headers GUC is a JSON object of lowercased header name -> value.
  # Multiple values for one header are joined with ", " (PostgREST behavior).
  defp headers_json(conn) do
    conn.req_headers
    |> Enum.reduce(%{}, fn {name, value}, acc ->
      key = String.downcase(name)

      Map.update(acc, key, value, fn existing -> existing <> ", " <> value end)
    end)
    |> Bier.json_library().encode!()
  end

  # request.cookies is a JSON object of parsed Cookie pairs.
  defp cookies_json(conn) do
    conn
    |> Plug.Conn.get_req_header("cookie")
    |> Enum.flat_map(&parse_cookie_header/1)
    |> Map.new()
    |> Bier.json_library().encode!()
  end

  # Cookies are separated by `;` (PostgREST also tolerates the `;`-without-space
  # form, e.g. `a=1;b=2`). Split on `;`, then each pair on the first `=`.
  defp parse_cookie_header(value) do
    value
    |> String.split(";")
    |> Enum.flat_map(fn pair ->
      case String.split(String.trim(pair), "=", parts: 2) do
        [k, v] -> [{k, v}]
        _ -> []
      end
    end)
  end
end
