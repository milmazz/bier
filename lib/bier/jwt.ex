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
    * unreadable token structure                    -> `:bad_crypto` (PGRST301, 401)
    * unsecured token (`alg: none`)                 -> `{:bad_algorithm, d}` (PGRST301, 401)
    * no key verified the signature                 -> `:jwt_invalid` (PGRST301, 401)
    * payload is not a JSON object                  -> `:claims_parse_failed` (PGRST303)
    * `exp` more than 30s in the past               -> `:expired` (PGRST303, 401)
    * `nbf` more than 30s in the future             -> `:not_yet_valid` (PGRST303, 401)
    * `iat` more than 30s in the future             -> `:issued_at_future` (PGRST303, 401)
    * non-numeric `exp`/`nbf`/`iat`                  -> `{:claim_not_number, claim}` (PGRST303)
    * `aud` not a string / array of strings          -> `:aud_not_string` (PGRST303)
    * audience mismatch (when `jwt-aud` configured)  -> `:not_in_audience` (PGRST303)

  ## The decode-stage taxonomy

  PostgREST hands the token to Haskell `jose-jwt`'s `JWT.decode`, whose only
  three failures it re-labels are `KeyError`, `BadAlgorithm` and `BadCrypto`
  (`Auth/Jwt.hs` `jwtDecodeError`), each rendered as a distinct PGRST301 body.
  The three arise as follows, and this module reproduces the same split:

    * `parseJwt` (`Jose/Internal/Parser.hs`) collapses **every** structural
      failure to `BadCrypto` — `first (const BadCrypto) $ parseOnly jwt bs`. It
      base64url-decodes the header, JSON-decodes it into a recognized header
      (`alg: none` is the unsecured header; anything else needs a string `alg`),
      then base64url-decodes the payload and the signature. Any of those failing
      is `:bad_crypto` here, `details: null` in the response.
    * an unsecured header reaches `decode`, which — PostgREST passes no expected
      encoding — throws `BadAlgorithm "JWT is unsecured but expected 'alg' was
      not 'none'"`. That jose message is surfaced verbatim as the response
      `details`, so it is carried in the error term.
    * otherwise the key set is filtered by what can verify the header's `alg`
      and each candidate is tried; nothing verifying is `KeyError`. Bier holds a
      single configured key, so its "wrong secret", "wrong key type" and
      "algorithm mismatch" outcomes are one bucket (`:jwt_invalid`), rendered
      with jose's `"None of the keys was able to decode the JWT"` details.

  Signatures are verified through `:jose`. The configured secret selects the key:
  a JWK (a JSON object with `kty`, or a JWK Set) verifies asymmetric algorithms
  (RS*/ES*/PS*/EdDSA); any other secret is an HMAC `oct` key (HS256/384/512).
  Routing on the secret — not just the token's `alg` — keeps a public JWK from
  ever being used as an HMAC key (an algorithm-confusion attempt is rejected).
  `alg: none` never reaches that step: an unsecured token is rejected while the
  token is still being parsed, so it can never authenticate.

  Returns `{:ok, %{role: role | nil, claims: map, claims_json: raw_json}}` where
  `claims_json` is the exact decoded payload JSON segment (re-encoded canonically)
  used to populate `request.jwt.claims`.

  Verification is split into public pieces so `Bier.Auth` can interpose a
  cache: `precheck/2` is the nil/empty/no-secret gate, then
  `decode_and_verify/2` (cacheable: signature + payload decode) and
  `validate_claims/3` (per-request: temporal + audience checks + role
  extraction). `Bier.JwtCache` caches only the expensive `decode_and_verify/2`
  results; `verify/4` recomposes all three for direct (uncached) use.
  """

  alias Bier.JWT.RoleClaim

  @default_role_claim_path [{:name, :dot, "role"}]

  @doc """
  Verify the bearer token from the `Authorization` header.

    * `nil` token (no header)         -> `{:ok, :anonymous}`
    * a present token, no secret      -> `{:error, :no_secret}`
    * a present, valid token          -> `{:ok, %{role:, claims:, claims_json:}}`
    * a present, invalid token        -> `{:error, reason}`

  `role_claim_path` is the parsed `jwt-role-claim-key` JSON Path
  (`Bier.JWT.RoleClaim`) locating the role inside the claims; it defaults to
  PostgREST's `$.role`.
  """
  @spec verify(String.t() | nil, String.t() | nil, String.t() | nil, RoleClaim.path()) ::
          {:ok, :anonymous}
          | {:ok, %{role: String.t() | nil, claims: map(), claims_json: String.t()}}
          | {:error, atom() | {atom(), term()}}
  def verify(token, secret, aud, role_claim_path \\ @default_role_claim_path) do
    case precheck(token, secret) do
      {:ok, :anonymous} -> {:ok, :anonymous}
      {:ok, trimmed} -> verify_token(trimmed, secret, aud, role_claim_path)
      {:error, _} = error -> error
    end
  end

  @doc """
  Pre-checks a bearer token ahead of the decode step: `nil` (no header) ->
  `{:ok, :anonymous}`, a blank token -> `{:error, :empty}`, no secret
  configured -> `{:error, :no_secret}`, otherwise `{:ok, trimmed_token}`.

  Shared by `verify/4` and `Bier.Auth`, which interposes `Bier.JwtCache`
  between this check and `decode_and_verify/2` rather than calling
  `verify_token/4` directly — keeping the check in one place means the two
  callers can't drift apart on it.
  """
  @spec precheck(String.t() | nil, String.t() | nil) ::
          {:ok, :anonymous} | {:ok, String.t()} | {:error, :empty | :no_secret}
  def precheck(nil, _secret), do: {:ok, :anonymous}

  def precheck(token, secret) when is_binary(token) do
    trimmed = String.trim(token)

    cond do
      trimmed == "" -> {:error, :empty}
      is_nil(secret) -> {:error, :no_secret}
      true -> {:ok, trimmed}
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
      [header_b64, payload_b64, signature_b64] ->
        with {:ok, payload_raw} <- parse_compact(header_b64, payload_b64, signature_b64),
             :ok <- verify_signature(token, secret),
             {:ok, claims} <- decode_claims(payload_raw) do
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

  # ---- structural parse (jose-jwt `parseJwt`) ------------------------------

  # jose's message for an unsecured token, surfaced verbatim as the response
  # `details` (PostgREST Error.hs renders `BadAlgorithm dets`).
  @unsecured_details "JWT is unsecured but expected 'alg' was not 'none'"

  # Mirror of jose-jwt's compact-token parser, in its order: header segment,
  # header object, then the payload and signature segments. Every failure it can
  # produce is `BadCrypto`; the one exception is the unsecured header, which the
  # parser accepts and `decode` then rejects as `BadAlgorithm`.
  defp parse_compact(header_b64, payload_b64, signature_b64) do
    with {:ok, header_raw} <- base64url_decode(header_b64),
         {:ok, header} <- json_object(header_raw),
         :ok <- check_header(header),
         {:ok, payload_raw} <- base64url_decode(payload_b64),
         {:ok, _signature} <- base64url_decode(signature_b64) do
      {:ok, payload_raw}
    else
      :error -> {:error, :bad_crypto}
      {:error, _reason} = error -> error
    end
  end

  # jose-jwt's `FromJSON JwtHeader`: `alg: "none"` is the unsecured header;
  # every other header has to carry a string `alg` to parse at all.
  defp check_header(%{"alg" => "none"}), do: {:error, {:bad_algorithm, @unsecured_details}}
  defp check_header(%{"alg" => alg}) when is_binary(alg), do: :ok
  defp check_header(_header), do: :error

  # ---- signature ----------------------------------------------------------

  @hmac_algs ~w(HS256 HS384 HS512)
  @asymmetric_algs ~w(RS256 RS384 RS512 ES256 ES384 ES512 PS256 PS384 PS512 EdDSA)

  # Verify the signature with `:jose`, routing on the SECRET rather than only the
  # token's `alg`: a JWK-shaped secret (a public key) is verified asymmetrically,
  # any other secret as an HMAC `oct` key. Each key type carries a fixed algorithm
  # allowlist, so a token whose `alg` doesn't match the key type — an HS256 token
  # presented against a public JWK (algorithm confusion) — is rejected, the same
  # filtering jose-jwt's `canDecodeJws` does before it tries a key.
  # `JOSE.JWS.verify_strict/3` compares HMACs in constant time, and a
  # malformed-key raise is caught here as an unverifiable token.
  defp verify_signature(token, secret) do
    {jwk, allowed} = key_and_algs(secret)

    case JOSE.JWS.verify_strict(jwk, allowed, token) do
      {true, _payload, _jws} -> :ok
      _ -> {:error, :jwt_invalid}
    end
  rescue
    _ -> {:error, :jwt_invalid}
  end

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

  # PostgREST allows 30 seconds of clock skew between the token issuer and this
  # server when checking the temporal claims (Auth/Jwt.hs `allowedSkewSeconds`).
  @allowed_skew_seconds 30

  # `exp`/`nbf`/`iat` must be numbers when present. With the skew allowance:
  # `exp` fails only once it is more than 30s in the past; `nbf` and `iat` fail
  # only when more than 30s in the future (Auth/Jwt.hs `inThePast`/`inTheFuture`).
  defp validate_temporal(claims) do
    now = System.system_time(:second)

    with :ok <- check_numeric(claims, "exp"),
         :ok <- check_numeric(claims, "nbf"),
         :ok <- check_numeric(claims, "iat") do
      cond do
        is_number(claims["exp"]) and claims["exp"] < now - @allowed_skew_seconds ->
          {:error, :expired}

        is_number(claims["nbf"]) and claims["nbf"] > now + @allowed_skew_seconds ->
          {:error, :not_yet_valid}

        is_number(claims["iat"]) and claims["iat"] > now + @allowed_skew_seconds ->
          {:error, :issued_at_future}

        true ->
          :ok
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
  # must contain it. An `aud` that is absent or explicitly `null` is skipped
  # rather than rejected — PostgREST reads it with `parseMaybe (.:? "aud")` and
  # only applies `audMatchesCfg` when that yields a value — and an empty-array
  # `aud` is likewise treated as "no audience" and ignored.
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
  defp check_aud_membership(nil, _expected), do: :ok
  defp check_aud_membership([], _expected), do: :ok

  defp check_aud_membership(aud, expected) when is_binary(aud),
    do: if(aud == expected, do: :ok, else: {:error, :not_in_audience})

  defp check_aud_membership(aud, expected) when is_list(aud),
    do: if(expected in aud, do: :ok, else: {:error, :not_in_audience})

  # ---- decoding helpers ---------------------------------------------------

  # The payload is only read once the signature verified, so a payload that
  # base64-decoded but is not a JSON object is a *claims* failure, not a decode
  # one: PostgREST's `parseClaims` yields `ParsingClaimsFailed` -> PGRST303.
  defp decode_claims(payload_raw) do
    case json_object(payload_raw) do
      {:ok, claims} -> {:ok, claims}
      :error -> {:error, :claims_parse_failed}
    end
  end

  defp json_object(raw) do
    case Bier.json_library().decode(raw) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _other -> :error
    end
  end

  defp base64url_decode(value) do
    Base.url_decode64(value, padding: false)
  end
end
