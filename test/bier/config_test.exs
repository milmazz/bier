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

  describe "parse_socket_mode/1" do
    test "valid octal modes in range parse to the integer file mode" do
      assert Bier.Config.parse_socket_mode("660") == {:ok, 0o660}
      assert Bier.Config.parse_socket_mode("600") == {:ok, 0o600}
      assert Bier.Config.parse_socket_mode("777") == {:ok, 0o777}
    end

    test "no leading octal digit is 'not an octal' (case 1714)" do
      assert Bier.Config.parse_socket_mode("800") ==
               {:error, "Invalid server-unix-socket-mode: not an octal"}

      assert Bier.Config.parse_socket_mode("mode") ==
               {:error, "Invalid server-unix-socket-mode: not an octal"}
    end

    test "reads the longest octal prefix like Haskell readOct (case 1715)" do
      # "599" parses as 5 (the 9s are not octal digits), which is out of range.
      assert Bier.Config.parse_socket_mode("599") ==
               {:error, "Invalid server-unix-socket-mode: needs to be between 600 and 777"}

      assert Bier.Config.parse_socket_mode("577") ==
               {:error, "Invalid server-unix-socket-mode: needs to be between 600 and 777"}
    end

    test "an invalid mode rejects the boot config even without a socket path" do
      assert_raise ArgumentError, ~r/not an octal/, fn ->
        Bier.Config.new!([server_unix_socket_mode: "abc"], Bier.schema())
      end
    end
  end

  describe "validate_proxy_uri/1" do
    test "nil and absolute http(s) URIs are ok" do
      assert Bier.Config.validate_proxy_uri(nil) == :ok
      assert Bier.Config.validate_proxy_uri("https://example.com:8443/basePath") == :ok
      assert Bier.Config.validate_proxy_uri("http://example.com") == :ok
    end

    test "malformed or non-http URIs are rejected with PostgREST's message (case 1716)" do
      message = "Malformed proxy uri, a correct example: https://example.com:8443/basePath"
      assert Bier.Config.validate_proxy_uri("htp:/@@localhorst.invalid") == {:error, message}
      assert Bier.Config.validate_proxy_uri("ftp://example.com") == {:error, message}
      assert Bier.Config.validate_proxy_uri("https://") == {:error, message}
      assert Bier.Config.validate_proxy_uri("not a uri") == {:error, message}
    end
  end

  describe "host_address/1" do
    test "maps the Warp HostPreference special forms" do
      assert Bier.Config.host_address("!4") == {0, 0, 0, 0}
      assert Bier.Config.host_address("*") == {0, 0, 0, 0}
      assert Bier.Config.host_address("*4") == {0, 0, 0, 0}
      assert Bier.Config.host_address("!6") == {0, 0, 0, 0, 0, 0, 0, 0}
      assert Bier.Config.host_address("*6") == {0, 0, 0, 0, 0, 0, 0, 0}
    end

    test "parses IP literals and resolves host names" do
      assert Bier.Config.host_address("127.0.0.1") == {127, 0, 0, 1}
      assert Bier.Config.host_address("::1") == {0, 0, 0, 0, 0, 0, 0, 1}
      assert Bier.Config.host_address("localhost") == {127, 0, 0, 1}
    end

    test "an unresolvable name raises" do
      assert_raise ArgumentError, ~r/not a bindable address/, fn ->
        Bier.Config.host_address("definitely-not-a-real-host.invalid")
      end
    end
  end

  describe "app_settings" do
    test "defaults to an empty map and accepts string pairs" do
      assert Bier.Config.new!([], Bier.schema()).app_settings == %{}

      config = Bier.Config.new!([app_settings: %{"foo" => "bar"}], Bier.schema())
      assert config.app_settings == %{"foo" => "bar"}
    end
  end

  describe "openapi_version" do
    test "defaults to 2.0 and accepts 3.0" do
      assert Bier.Config.new!([], Bier.schema()).openapi_version == "2.0"
      assert Bier.Config.new!([openapi_version: "3.0"], Bier.schema()).openapi_version == "3.0"
    end

    test "rejects unknown versions" do
      assert_raise ArgumentError, ~r/openapi_version/, fn ->
        Bier.Config.new!([openapi_version: "3.1"], Bier.schema())
      end
    end
  end
end
