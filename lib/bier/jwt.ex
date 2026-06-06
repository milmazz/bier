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
    * `nbf`/`iat`/`exp`/`aud` of the wrong JSON type -> `:jwt_invalid` (PGRST301)
    * audience mismatch (when `jwt-aud` configured)  -> `:jwt_invalid` (PGRST301)

  Only HS256/HS384/HS512 (symmetric) are supported; an asymmetric (RS*/ES*)
  token cannot be verified with a symmetric secret and is rejected.

  Returns `{:ok, %{role: role | nil, claims: map, claims_json: raw_json}}` where
  `claims_json` is the exact decoded payload JSON segment (re-encoded canonically)
  used to populate `request.jwt.claims`.
  """

  @doc """
  Verify the bearer token from the `Authorization` header.

    * `nil` token (no header)         -> `{:ok, :anonymous}`
    * a present token, no secret      -> `{:error, :no_secret}`
    * a present, valid token          -> `{:ok, %{role:, claims:, claims_json:}}`
    * a present, invalid token        -> `{:error, reason}`
  """
  @spec verify(String.t() | nil, String.t() | nil, String.t() | nil) ::
          {:ok, :anonymous}
          | {:ok, %{role: String.t() | nil, claims: map(), claims_json: String.t()}}
          | {:error, atom() | {atom(), term()}}
  def verify(nil, _secret, _aud), do: {:ok, :anonymous}

  def verify(token, secret, aud) when is_binary(token) do
    trimmed = String.trim(token)

    cond do
      trimmed == "" ->
        {:error, :empty}

      is_nil(secret) ->
        {:error, :no_secret}

      true ->
        verify_token(trimmed, secret, aud)
    end
  end

  defp verify_token(token, secret, aud) do
    parts = String.split(token, ".")

    case parts do
      [header_b64, payload_b64, sig_b64] ->
        with {:ok, header} <- decode_segment(header_b64),
             {:ok, alg} <- algorithm(header),
             :ok <- verify_signature(alg, header_b64, payload_b64, sig_b64, secret),
             {:ok, payload_raw} <- decode_segment_raw(payload_b64),
             {:ok, claims} <- decode_json(payload_raw),
             :ok <- validate_temporal(claims),
             :ok <- validate_audience(claims, aud) do
          {:ok,
           %{
             role: role_claim(claims),
             claims: claims,
             claims_json: Bier.json_library().encode!(claims)
           }}
        end

      other ->
        {:error, {:parts, length(other)}}
    end
  end

  # ---- signature ----------------------------------------------------------

  defp algorithm(%{"alg" => alg}) when is_binary(alg) do
    case alg do
      "HS256" -> {:ok, :sha256}
      "HS384" -> {:ok, :sha384}
      "HS512" -> {:ok, :sha512}
      # Asymmetric / unsupported algorithms cannot be verified with a symmetric
      # secret; PostgREST rejects them as invalid tokens.
      _ -> {:error, :jwt_invalid}
    end
  end

  defp algorithm(_), do: {:error, :jwt_invalid}

  defp verify_signature(digest, header_b64, payload_b64, sig_b64, secret) do
    signing_input = header_b64 <> "." <> payload_b64
    expected = :crypto.mac(:hmac, digest, secret, signing_input)

    case base64url_decode(sig_b64) do
      {:ok, actual} ->
        if secure_compare(expected, actual), do: :ok, else: {:error, :jwt_invalid}

      :error ->
        {:error, :jwt_invalid}
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
      {:ok, _} -> {:error, :jwt_invalid}
      :error -> :ok
    end
  end

  # When `jwt-aud` is configured, the token's `aud` must contain it. `aud` may be
  # a string or an array of strings; any other shape (or a non-matching value) is
  # invalid. An absent/empty `aud` with a configured audience is rejected; an
  # empty-array `aud` is treated as "no audience" and ignored.
  defp validate_audience(_claims, nil), do: :ok
  defp validate_audience(_claims, ""), do: :ok

  defp validate_audience(claims, expected) do
    case Map.get(claims, "aud") do
      nil -> {:error, :jwt_invalid}
      [] -> :ok
      aud when is_binary(aud) -> if aud == expected, do: :ok, else: {:error, :jwt_invalid}
      aud when is_list(aud) -> if expected in aud, do: :ok, else: {:error, :jwt_invalid}
      _ -> {:error, :jwt_invalid}
    end
  end

  defp role_claim(%{"role" => role}) when is_binary(role) and role != "", do: role
  defp role_claim(_), do: nil

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

  defp secure_compare(a, b) when byte_size(a) == byte_size(b) do
    :crypto.hash_equals(a, b)
  end

  defp secure_compare(_a, _b), do: false
end
