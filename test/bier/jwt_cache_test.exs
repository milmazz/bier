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

  describe "telemetry helpers" do
    test "jwt_cache_lookup/2 and jwt_cache_eviction/1 emit the #36 events" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:bier, :jwt_cache, :lookup],
          [:bier, :jwt_cache, :eviction]
        ])

      Bier.Telemetry.jwt_cache_lookup(true, %{instance: Some.Instance})
      Bier.Telemetry.jwt_cache_lookup(false, %{instance: Some.Instance})
      Bier.Telemetry.jwt_cache_eviction(%{instance: Some.Instance})

      assert_receive {[:bier, :jwt_cache, :lookup], ^ref, %{count: 1},
                      %{hit: true, instance: Some.Instance}}

      assert_receive {[:bier, :jwt_cache, :lookup], ^ref, %{count: 1},
                      %{hit: false, instance: Some.Instance}}

      assert_receive {[:bier, :jwt_cache, :eviction], ^ref, %{count: 1},
                      %{instance: Some.Instance}}
    end
  end
end
