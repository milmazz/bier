defmodule Bier.JWT do
  @moduledoc """
  Minimal JWT verification for the auth pipeline.

  PostgREST authenticates a request by verifying the `Authorization: Bearer
  <token>` JWT against the configured `jwt-secret`, then switching the database
  role to the token's `role` claim (falling back to the anonymous role). This
  module performs only the *verification* half — it never mints tokens (the
  conformance cases carry hardcoded tokens) — and maps each failure to the
  PostgREST error the cases expect:

    * no secret configured but a token is presented -> `:no_secret` (PGRST300, 500)
    * empty bearer token                            -> `:empty` (PGRST301, 401)
    * not exactly 3 dot-separated parts             -> `{:parts, n}` (PGRST301, 401)
    * bad base64 / JSON / signature                 -> `:jwt_invalid` (PGRST301, 401)
    * `exp` in the past                             -> `:expired` (PGRST303, 401)
    * non-numeric `exp`/`nbf`/`iat`                  -> `{:claim_not_number, claim}` (PGRST303)
    * `aud` not a string / array of strings          -> `:aud_not_string` (PGRST303)
    * audience mismatch (when `jwt-aud` configured)  -> `:not_in_audience` (PGRST303)

  Signatures are verified through `:jose`. The configured secret selects the key:
  a JWK (a JSON object with `kty`, or a JWK Set) verifies asymmetric algorithms
  (RS*/ES*/PS*/EdDSA); any other secret is an HMAC `oct` key (HS256/384/512).
  Routing on the secret — not just the token's `alg` — keeps a public JWK from
  ever being used as an HMAC key (an algorithm-confusion attempt is rejected), and
  the fixed per-key-type allowlist also rejects `alg: none`.

  Returns `{:ok, %{role: role | nil, claims: map, claims_json: raw_json}}` where
  `claims_json` is the exact decoded payload JSON segment (re-encoded canonically)
  used to populate `request.jwt.claims`.

  Verification is split into two public halves for caching: `decode_and_verify/2`
  (cacheable: signature + payload decode) and `validate_claims/3` (per-request:
  temporal + audience checks + role extraction). `Bier.JwtCache` caches only the
  expensive `decode_and_verify/2` results; `verify/4` recomposes them.
  """

  alias Bier.JWT.RoleClaim

  @default_role_claim_path [{:key, "role"}]

  @doc """
  Verify the bearer token from the `Authorization` header.

    * `nil` token (no header)         -> `{:ok, :anonymous}`
    * a present token, no secret      -> `{:error, :no_secret}`
    * a present, valid token          -> `{:ok, %{role:, claims:, claims_json:}}`
    * a present, invalid token        -> `{:error, reason}`

  `role_claim_path` is the parsed `jwt-role-claim-key` JSPath
  (`Bier.JWT.RoleClaim`) locating the role inside the claims; it defaults to
  PostgREST's `.role`.
  """
  @spec verify(String.t() | nil, String.t() | nil, String.t() | nil, RoleClaim.path()) ::
          {:ok, :anonymous}
          | {:ok, %{role: String.t() | nil, claims: map(), claims_json: String.t()}}
          | {:error, atom() | {atom(), term()}}
  def verify(token, secret, aud, role_claim_path \\ @default_role_claim_path)

  def verify(nil, _secret, _aud, _role_claim_path), do: {:ok, :anonymous}

  def verify(token, secret, aud, role_claim_path) when is_binary(token) do
    trimmed = String.trim(token)

    cond do
      trimmed == "" ->
        {:error, :empty}

      is_nil(secret) ->
        {:error, :no_secret}

      true ->
        verify_token(trimmed, secret, aud, role_claim_path)
    end
  end

  defp verify_token(token, secret, aud, role_claim_path) do
    with {:ok, claims, claims_json} <- decode_and_verify(token, secret),
         {:ok, role} <- validate_claims(claims, aud, role_claim_path) do
      {:ok, %{role: role, claims: claims, claims_json: claims_json}}
    end
  end

  @doc """
  The cacheable half of verification (PostgREST `parseAndDecodeClaims`):
  splits the token, verifies the signature against `secret`, and decodes the
  payload. Returns the claims plus the canonically re-encoded payload JSON
  used for `request.jwt.claims`. Assumes a non-empty token and a present
  secret — callers keep the `:empty`/`:no_secret` pre-checks. `Bier.JwtCache`
  caches exactly this function's successful result, keyed by the token.
  """
  @spec decode_and_verify(String.t(), String.t()) ::
          {:ok, map(), String.t()} | {:error, atom() | {atom(), term()}}
  def decode_and_verify(token, secret) do
    case String.split(token, ".") do
      [header_b64, payload_b64, _sig_b64] ->
        with {:ok, header} <- decode_segment(header_b64),
             :ok <- verify_signature(header, token, secret),
             {:ok, payload_raw} <- decode_segment_raw(payload_b64),
             {:ok, claims} <- decode_json(payload_raw) do
          {:ok, claims, Bier.json_library().encode!(claims)}
        end

      other ->
        {:error, {:parts, length(other)}}
    end
  end

  @doc """
  The per-request half (PostgREST `validateClaims` + role extraction):
  temporal (`exp`/`nbf`/`iat`) and audience checks, then the role claim.
  Runs on every request — cache hit or not — so a cached token still starts
  failing once its `exp` passes.
  """
  @spec validate_claims(map(), String.t() | nil, RoleClaim.path()) ::
          {:ok, String.t() | nil} | {:error, atom() | {atom(), term()}}
  def validate_claims(claims, aud, role_claim_path) do
    with :ok <- validate_temporal(claims),
         :ok <- validate_audience(claims, aud) do
      {:ok, RoleClaim.extract(claims, role_claim_path)}
    end
  end

  # ---- signature ----------------------------------------------------------

  @hmac_algs ~w(HS256 HS384 HS512)
  @asymmetric_algs ~w(RS256 RS384 RS512 ES256 ES384 ES512 PS256 PS384 PS512 EdDSA)

  # Verify the signature with `:jose`, routing on the SECRET rather than only the
  # token's `alg`: a JWK-shaped secret (a public key) is verified asymmetrically,
  # any other secret as an HMAC `oct` key. Each key type carries a fixed algorithm
  # allowlist, so a token whose `alg` doesn't match the key type — `alg: none`, or
  # an HS256 token presented against a public JWK (algorithm confusion) — is
  # rejected. `JOSE.JWS.verify_strict/3` compares HMACs in constant time, and a
  # malformed-key raise is caught here as an invalid token.
  defp verify_signature(%{"alg" => alg}, token, secret) when is_binary(alg) do
    {jwk, allowed} = key_and_algs(secret)

    case JOSE.JWS.verify_strict(jwk, allowed, token) do
      {true, _payload, _jws} -> :ok
      _ -> {:error, :jwt_invalid}
    end
  rescue
    _ -> {:error, :jwt_invalid}
  end

  defp verify_signature(_header, _token, _secret), do: {:error, :jwt_invalid}

  # Build the verification key + its algorithm allowlist from the configured
  # secret. A JWK (a JSON object with `kty`, or the first key of a JWK Set) is an
  # asymmetric key; anything else is an HMAC `oct` key. Pinning the allowlist to
  # the key type is what stops the two families from crossing.
  defp key_and_algs(secret) do
    case Bier.json_library().decode(secret) do
      {:ok, %{"keys" => [key | _]}} when is_map(key) -> {JOSE.JWK.from_map(key), @asymmetric_algs}
      {:ok, %{"kty" => _} = map} -> {JOSE.JWK.from_map(map), @asymmetric_algs}
      _ -> {JOSE.JWK.from_oct(secret), @hmac_algs}
    end
  end

  # ---- claims validation --------------------------------------------------

  # `exp`/`nbf`/`iat` must be numbers when present. `exp` must be in the future;
  # `nbf` must not be in the future. PostgREST mirrors the JOSE spec here.
  defp validate_temporal(claims) do
    now = System.system_time(:second)

    with :ok <- check_numeric(claims, "exp"),
         :ok <- check_numeric(claims, "nbf"),
         :ok <- check_numeric(claims, "iat") do
      cond do
        is_number(claims["exp"]) and claims["exp"] <= now -> {:error, :expired}
        is_number(claims["nbf"]) and claims["nbf"] > now -> {:error, :jwt_invalid}
        true -> :ok
      end
    end
  end

  defp check_numeric(claims, key) do
    case Map.fetch(claims, key) do
      {:ok, v} when is_number(v) -> :ok
      {:ok, _} -> {:error, {:claim_not_number, key}}
      :error -> :ok
    end
  end

  # A present `aud` must be a string or an array of strings — even when no
  # `jwt-aud` is configured (PostgREST type-checks the claim unconditionally).
  # Membership is only enforced when `jwt-aud` is configured: the token's `aud`
  # must contain it. An absent `aud` with a configured audience is rejected; an
  # empty-array `aud` is treated as "no audience" and ignored.
  defp validate_audience(claims, expected) do
    aud = Map.get(claims, "aud")

    with :ok <- check_aud_type(aud) do
      check_aud_membership(aud, expected)
    end
  end

  defp check_aud_type(aud) when is_nil(aud) or is_binary(aud), do: :ok

  defp check_aud_type(aud) when is_list(aud) do
    if Enum.all?(aud, &is_binary/1), do: :ok, else: {:error, :aud_not_string}
  end

  defp check_aud_type(_aud), do: {:error, :aud_not_string}

  defp check_aud_membership(_aud, expected) when is_nil(expected) or expected == "", do: :ok
  defp check_aud_membership(nil, _expected), do: {:error, :jwt_invalid}
  defp check_aud_membership([], _expected), do: :ok

  defp check_aud_membership(aud, expected) when is_binary(aud),
    do: if(aud == expected, do: :ok, else: {:error, :not_in_audience})

  defp check_aud_membership(aud, expected) when is_list(aud),
    do: if(expected in aud, do: :ok, else: {:error, :not_in_audience})

  # ---- decoding helpers ---------------------------------------------------

  defp decode_segment(b64) do
    with {:ok, raw} <- decode_segment_raw(b64) do
      decode_json(raw)
    end
  end

  defp decode_segment_raw(b64) do
    case base64url_decode(b64) do
      {:ok, raw} -> {:ok, raw}
      :error -> {:error, :jwt_invalid}
    end
  end

  defp decode_json(raw) do
    case Bier.json_library().decode(raw) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, :jwt_invalid}
    end
  end

  defp base64url_decode(value) do
    Base.url_decode64(value, padding: false)
  end
end
