defmodule Bier.HealthTest do
  use ExUnit.Case, async: true

  describe "ready?/1" do
    test "is false when the schema cache is absent (no DB ping needed)" do
      # An instance name that was never booted has no :persistent_term relations
      # entry and no Postgrex pool. ready?/1 must short-circuit to false on the
      # empty cache without raising on the missing pool.
      name = :"never_booted_#{System.unique_integer([:positive])}"
      refute Bier.Health.ready?(name)
    end

    test "is false when the schema cache is present but empty" do
      name = :"empty_cache_#{System.unique_integer([:positive])}"
      :persistent_term.put({Bier, :relations, name}, %{})
      on_exit(fn -> :persistent_term.erase({Bier, :relations, name}) end)
      refute Bier.Health.ready?(name)
    end
  end
end
