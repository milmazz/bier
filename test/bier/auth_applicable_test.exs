defmodule Bier.AuthApplicableTest do
  use ExUnit.Case, async: true

  alias Bier.Auth
  alias Bier.ConformanceServer

  defp config(opts) do
    base = [name: :"auth_applicable_#{System.unique_integer([:positive])}"]
    Bier.Config.new!(base ++ opts, Bier.schema())
  end

  test "applicable? is true when a jwt_secret is configured" do
    assert Auth.applicable?(config(jwt_secret: String.duplicate("x", 32)))
  end

  test "applicable? is true when a db_anon_role is configured" do
    assert Auth.applicable?(config(db_anon_role: "web_anon"))
  end

  test "applicable? is false when neither is configured" do
    refute Auth.applicable?(config([]))
  end

  test "base_opts (bulk) has auth disabled; auth_opts enables it" do
    refute Auth.applicable?(config(ConformanceServer.base_opts()))
    assert Auth.applicable?(config(ConformanceServer.auth_opts()))
  end
end
