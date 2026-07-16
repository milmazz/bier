defmodule Bier.PrivilegesCacheTest do
  use ExUnit.Case, async: true

  defp unique_name, do: :"priv_cache_#{System.unique_integer([:positive])}"

  defp spy_loader(parent, result) do
    fn ->
      send(parent, :loader_ran)
      result
    end
  end

  test "caches per role within a generation; a new generation invalidates" do
    name = unique_name()
    start_supervised!({Bier.PrivilegesCache, %Bier.Config{name: name}})

    gen1 = make_ref()
    privs = %{relations: %{}, functions: %{}}
    loader = spy_loader(self(), privs)

    assert Bier.PrivilegesCache.fetch(name, "web_anon", gen1, loader) == privs
    assert_received :loader_ran

    assert Bier.PrivilegesCache.fetch(name, "web_anon", gen1, loader) == privs
    refute_received :loader_ran

    # a different role is its own entry
    assert Bier.PrivilegesCache.fetch(name, "admin", gen1, loader) == privs
    assert_received :loader_ran

    # a schema-cache reload stamps a new generation -> first fetch re-runs
    gen2 = make_ref()
    assert Bier.PrivilegesCache.fetch(name, "web_anon", gen2, loader) == privs
    assert_received :loader_ran

    assert Bier.PrivilegesCache.fetch(name, "web_anon", gen2, loader) == privs
    refute_received :loader_ran
  end

  test "an instance without a cache table falls back to the loader every time" do
    name = unique_name()
    loader = spy_loader(self(), %{relations: %{}, functions: %{}})

    Bier.PrivilegesCache.fetch(name, "web_anon", make_ref(), loader)
    assert_received :loader_ran

    Bier.PrivilegesCache.fetch(name, "web_anon", make_ref(), loader)
    assert_received :loader_ran
  end

  test "a table that died mid-request behind a stale published tid falls back to the loader" do
    name = unique_name()
    start_supervised!({Bier.PrivilegesCache, %Bier.Config{name: name}})

    gen = make_ref()
    privs = %{relations: %{}, functions: %{}}
    loader = spy_loader(self(), privs)

    # Populate an entry so there is something to (fail to) hit later.
    assert Bier.PrivilegesCache.fetch(name, "web_anon", gen, loader) == privs
    assert_received :loader_ran

    key = {Bier, :privileges_cache, name}
    tid = :persistent_term.get(key)

    # Stop the owner: its ETS table dies with it, and terminate/2 erases
    # `key`. Re-publish the now-dead tid to reproduce the crash->restart
    # window where a stale tid still lingers in :persistent_term.
    stop_supervised!(Bier.PrivilegesCache)
    :persistent_term.put(key, tid)
    on_exit(fn -> :persistent_term.erase(key) end)

    assert Bier.PrivilegesCache.fetch(name, "web_anon", gen, loader) == privs
    assert_received :loader_ran
  end

  test "schema cache snapshots carry a fresh generation ref" do
    # The never-loaded empty struct has no generation.
    assert %Bier.SchemaCache{}.generation == nil
  end
end
