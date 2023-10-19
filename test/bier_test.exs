defmodule BierTest do
  use ExUnit.Case
  doctest Bier

  test "greets the world" do
    assert Bier.hello() == :world
  end
end
