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
end
