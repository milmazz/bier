defmodule Bier.ConfigTest do
  use ExUnit.Case, async: true

  describe "validate_jwt_secret/1" do
    test "nil and >= 32 chars are ok" do
      assert Bier.Config.validate_jwt_secret(nil) == :ok
      assert Bier.Config.validate_jwt_secret(String.duplicate("a", 32)) == :ok
    end

    test "shorter than 32 chars is rejected with PostgREST's message" do
      assert Bier.Config.validate_jwt_secret("short_secret") ==
               {:error, "The JWT secret must be at least 32 characters long."}
    end

    test "counts bytes like PostgREST (BS.length), not graphemes" do
      # 16 × "é" is 16 graphemes but 32 UTF-8 bytes — PostgREST accepts it.
      assert Bier.Config.validate_jwt_secret(String.duplicate("é", 16)) == :ok
    end
  end

  describe "validate_admin_server_port/2" do
    test "nil admin port or differing ports are ok" do
      assert Bier.Config.validate_admin_server_port(nil, 3000) == :ok
      assert Bier.Config.validate_admin_server_port(3001, 3000) == :ok
    end

    test "equal ports are rejected with PostgREST's message" do
      assert Bier.Config.validate_admin_server_port(3000, 3000) ==
               {:error, "admin-server-port cannot be the same as server-port"}
    end
  end

  describe "validate_jwt_aud/1" do
    test "nil and a plain string are ok" do
      assert Bier.Config.validate_jwt_aud(nil) == :ok
      assert Bier.Config.validate_jwt_aud("my-audience") == :ok
    end

    test "a value containing ':' must be a valid URI" do
      assert Bier.Config.validate_jwt_aud("https://example.com/aud") == :ok
      assert Bier.Config.validate_jwt_aud("urn:example:audience") == :ok

      assert Bier.Config.validate_jwt_aud("foo://%%$$^^.com") ==
               {:error, "jwt-aud should be a string or a valid URI"}
    end
  end

  describe "new!/2 enforces the validators" do
    test "a too-short jwt_secret raises" do
      assert_raise ArgumentError, ~r/JWT secret must be at least 32/, fn ->
        Bier.Config.new!([jwt_secret: "short_secret"], Bier.schema())
      end
    end

    test "an invalid jwt_aud raises" do
      assert_raise ArgumentError, ~r/jwt-aud should be a string or a valid URI/, fn ->
        Bier.Config.new!([jwt_aud: "foo://%%$$^^.com"], Bier.schema())
      end
    end
  end

  describe "decode_base64_secret/1 (jwt-secret-is-base64)" do
    test "decodes standard and URL-safe base64 (PostgREST's char replacement)" do
      raw = :crypto.strong_rand_bytes(32)
      assert Bier.Config.decode_base64_secret(Base.encode64(raw)) == {:ok, raw}

      # PostgREST replaces `-`->`+`, `_`->`/`, `.`->`=` before decoding.
      url_safe = raw |> Base.url_encode64() |> String.replace("=", ".")
      assert Bier.Config.decode_base64_secret(url_safe) == {:ok, raw}
    end

    test "surrounding whitespace is stripped" do
      raw = :crypto.strong_rand_bytes(32)
      assert Bier.Config.decode_base64_secret("  #{Base.encode64(raw)}\n") == {:ok, raw}
    end

    test "invalid base64 is rejected (case 1718)" do
      assert {:error, "the jwt-secret is not valid base64"} =
               Bier.Config.decode_base64_secret("no base-64!")
    end

    test "new!/2 stores the decoded secret; an undecodable one raises" do
      raw = :crypto.strong_rand_bytes(32)

      config =
        Bier.Config.new!(
          [jwt_secret: Base.encode64(raw), jwt_secret_is_base64: true],
          Bier.schema()
        )

      assert config.jwt_secret == raw

      assert_raise ArgumentError, ~r/not valid base64/, fn ->
        Bier.Config.new!(
          [jwt_secret: String.duplicate("no base-64!", 3), jwt_secret_is_base64: true],
          Bier.schema()
        )
      end
    end
  end

  describe "jwt_role_claim_key" do
    test "parses into jwt_role_claim_path at boot (default .role)" do
      config = Bier.Config.new!([], Bier.schema())
      assert config.jwt_role_claim_path == [{:key, "role"}]

      config = Bier.Config.new!([jwt_role_claim_key: ".realm.roles[0]"], Bier.schema())
      assert config.jwt_role_claim_path == [{:key, "realm"}, {:key, "roles"}, {:idx, 0}]
    end

    test "an invalid JSPath raises with PostgREST's message (case 1711)" do
      assert_raise ArgumentError, ~r/failed to parse role-claim-key value \(role\.other\)/, fn ->
        Bier.Config.new!([jwt_role_claim_key: "role.other"], Bier.schema())
      end
    end
  end
end
