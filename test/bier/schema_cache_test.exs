defmodule Bier.SchemaCacheTest do
  @moduledoc """
  Unit tests for the single-key schema-cache snapshot. Instance names are
  unique per test so the shared conformance instance's cache is never touched.
  """
  use ExUnit.Case, async: true

  alias Bier.SchemaCache

  defp unique_name, do: :"schema_cache_test_#{System.unique_integer([:positive])}"

  describe "get/1 and loaded?/1 on a never-loaded instance" do
    test "returns an empty snapshot and reports not loaded" do
      name = unique_name()

      assert %SchemaCache{
               relations: %{},
               functions: %{},
               media_handlers: [],
               schema_comment: nil
             } = SchemaCache.get(name)

      refute SchemaCache.loaded?(name)
    end
  end

  describe "put/2" do
    test "swaps the whole snapshot atomically under one persistent_term key" do
      name = unique_name()
      on_exit(fn -> :persistent_term.erase({Bier, :schema_cache, name}) end)

      cache = %SchemaCache{
        relations: %{{"public", "users"} => :fake_relation},
        functions: %{{"public", "fn"} => [:fake_overload]},
        media_handlers: [:fake_handler],
        schema_comment: "a comment"
      }

      assert :ok = SchemaCache.put(name, cache)

      assert SchemaCache.get(name) == cache
      assert SchemaCache.relations(name) == cache.relations
      assert SchemaCache.functions(name) == cache.functions
      assert SchemaCache.media_handlers(name) == cache.media_handlers
      assert SchemaCache.schema_comment(name) == "a comment"
      assert SchemaCache.loaded?(name)

      # The snapshot is ONE persistent_term entry — the atomic-swap guarantee.
      assert :persistent_term.get({Bier, :schema_cache, name}) == cache
    end

    test "loaded?/1 is false for a present but empty snapshot" do
      name = unique_name()
      on_exit(fn -> :persistent_term.erase({Bier, :schema_cache, name}) end)

      assert :ok = SchemaCache.put(name, %SchemaCache{})
      refute SchemaCache.loaded?(name)
    end
  end
end
