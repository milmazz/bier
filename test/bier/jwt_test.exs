defmodule Bier.JWTTest do
  use ExUnit.Case, async: true

  alias Bier.JWT

  # PostgREST's `testCfgAsymJWK` public key (RS256). The token below is signed
  # with the matching upstream private key — we only ever verify, never mint.
  @rsa_jwk ~s({"alg":"RS256","e":"AQAB","key_ops":["verify"],"kty":"RSA","n":"0etQ2Tg187jb04MWfpuogYGV75IFrQQBxQaGH75eq_FpbkyoLcEpRUEWSbECP2eeFya2yZ9vIO5ScD-lPmovePk4Aa4SzZ8jdjhmAbNykleRPCxMg0481kz6PQhnHRUv3nF5WP479CnObJKqTVdEagVL66oxnX9VhZG9IZA7k0Th5PfKQwrKGyUeTGczpOjaPqbxlunP73j9AfnAt4XCS8epa-n3WGz1j-wfpr_ys57Aq-zBCfqP67UYzNpeI1AoXsJhD9xSDOzvJgFRvc3vm2wjAW4LEMwi48rCplamOpZToIHEPIaPzpveYQwDnB1HFTR1ove9bpKJsHmi-e2uzQ","use":"sig"})

  # Real RS256 token from PostgREST's AsymmetricJwtSpec; claims {"role": "postgrest_test_author"}.
  @rs256_token "eyJhbGciOiJSUzI1NiJ9.eyJyb2xlIjogInBvc3RncmVzdF90ZXN0X2F1dGhvciJ9Cg.CBOYWDvqgAR0YYnZnyDGTQi6AJLc2Pds6_eV3YuBG6I36mj_h05eLhkEKNEDA5ZteMzCiY83P60rC_xtxVd7B6vo3BeF5uoanPS3rrbuHzKPwzsrgrD_CqvEuJ4n7Q9epkQiLsNkcexneENZDRqFjbwZx3DrXiCWwlK3Ytr5NAIGxmy0od-0xNpb2U1nXQyO_Q3mumWFViRt4tmFn_3goDHNKG3Ha_AzImfUNvHnWL78kAc4rbn15vLtWXD8PwtSnZaB4lY4V6RfsaW937srQsmRetvytM1i_bHBnjkjQLAqGbXPyItjtlXPs0uGNBadE8-wgkLtfmSCC4v2DjUthw"

  @hs_secret "reallyreallyreallyreallyverysafe"

  describe "asymmetric (RS256) verification" do
    test "verifies a token signed with the matching private key" do
      assert {:ok, %{role: "postgrest_test_author"}} = JWT.verify(@rs256_token, @rsa_jwk, nil)
    end

    # The algorithm-confusion attack: a public JWK is, by definition, known. An
    # attacker forges an HS256 token using the JWK's JSON bytes as the HMAC key.
    # Routing on the secret (JWK -> asymmetric path only) must reject it rather
    # than HMAC-verify it.
    test "rejects an HS256 token forged with the JWK bytes as the HMAC key" do
      forged = forge_hs256(%{"role" => "postgrest_test_superuser"}, @rsa_jwk)
      assert {:error, :jwt_invalid} = JWT.verify(forged, @rsa_jwk, nil)
    end

    test "rejects an RS256 token when the configured secret is symmetric" do
      assert {:error, :jwt_invalid} = JWT.verify(@rs256_token, @hs_secret, nil)
    end
  end

  describe "symmetric (HS256) verification still works" do
    test "verifies a token signed with the shared secret" do
      token = forge_hs256(%{"role" => "alice"}, @hs_secret)
      assert {:ok, %{role: "alice"}} = JWT.verify(token, @hs_secret, nil)
    end

    test "rejects a token signed with the wrong secret" do
      token = forge_hs256(%{"role" => "alice"}, "a-different-but-equally-long-secret")
      assert {:error, :jwt_invalid} = JWT.verify(token, @hs_secret, nil)
    end
  end

  describe "jwt-role-claim-key (verify/4)" do
    test "extracts the role from a custom nested path" do
      {:ok, path} = Bier.JWT.RoleClaim.parse(".realm.roles[1]")
      token = forge_hs256(%{"realm" => %{"roles" => ["writer", "admin"]}}, @hs_secret)
      assert {:ok, %{role: "admin"}} = JWT.verify(token, @hs_secret, nil, path)
    end

    test "a token whose claims miss the custom path yields a nil role" do
      {:ok, path} = Bier.JWT.RoleClaim.parse(".realm.roles[1]")
      token = forge_hs256(%{"role" => "alice"}, @hs_secret)
      assert {:ok, %{role: nil}} = JWT.verify(token, @hs_secret, nil, path)
    end

    test "verify/3 keeps the default .role path" do
      token = forge_hs256(%{"role" => "alice"}, @hs_secret)
      assert {:ok, %{role: "alice"}} = JWT.verify(token, @hs_secret, nil)
    end
  end

  describe "jwt-secret-is-base64 (decoded secret end to end)" do
    test "a token signed with the raw bytes verifies against the decoded secret" do
      raw = :crypto.strong_rand_bytes(32)
      encoded = Base.encode64(raw)

      config =
        Bier.Config.new!(
          [jwt_secret: encoded, jwt_secret_is_base64: true],
          Bier.schema()
        )

      assert config.jwt_secret == raw

      token = forge_hs256(%{"role" => "alice"}, raw)
      assert {:ok, %{role: "alice"}} = JWT.verify(token, config.jwt_secret, nil)
      # The undecoded text must NOT verify it.
      assert {:error, :jwt_invalid} = JWT.verify(token, encoded, nil)
    end
  end

  # Mint an HS256 token (header.payload.signature) signing with `key` as the HMAC
  # secret. Used only to construct test inputs.
  defp forge_hs256(claims, key) do
    header = b64(~s({"alg":"HS256"}))
    payload = b64(Bier.json_library().encode!(claims))
    signing_input = header <> "." <> payload
    sig = b64(:crypto.mac(:hmac, :sha256, key, signing_input))
    signing_input <> "." <> sig
  end

  defp b64(bin), do: Base.url_encode64(bin, padding: false)
end
