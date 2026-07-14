defmodule Bier.JwtCacheTest do
  use ExUnit.Case, async: true

  describe "config" do
    test "jwt_cache_max_entries defaults to 1000 (PostgREST parity)" do
      conf = Bier.Config.new!([], Bier.schema())
      assert conf.jwt_cache_max_entries == 1000
    end

    test "jwt_cache_max_entries is configurable, 0 disables" do
      conf = Bier.Config.new!([jwt_cache_max_entries: 0], Bier.schema())
      assert conf.jwt_cache_max_entries == 0
    end
  end
end
