defmodule Bier.Wal.RecheckTest do
  @moduledoc """
  Which failures of the central re-authorization (`Bier.Wal.notify_recheck/1`)
  close a live subscription, and which leave it standing (#150).

  Only a confirmed privilege loss may revoke: the subscriber's role no longer
  exists (`42704 undefined_object`). Any other database error says nothing
  about the role's privileges — closing on it would cut every subscriber of
  that role loose over a transient fault — so it keeps the subscription and
  the next reload re-checks.

  Needs no instance: `notify_recheck/1` only reads the instance's config from
  `Bier.Registry` and checks out of its registered pool, so this test
  registers both itself.
  """
  use ExUnit.Case, async: false

  # Any ordinary table works: the role is resolved per column, so the check
  # has to reach a real relation for the role lookup to run at all.
  @table {"pg_catalog", "pg_class"}

  setup do
    name = :"wal_recheck_#{System.unique_integer([:positive])}"
    conf = struct!(Bier.Config, name: name, events_publication: "wal_recheck_irrelevant")
    {:ok, _} = Registry.register(Bier.Registry, name, conf)

    pool_opts =
      Bier.ConformanceServer.base_opts()
      |> Keyword.put(:pool_size, 1)
      |> Keyword.put(:name, Bier.Registry.via(name, Postgrex))

    start_supervised!({Postgrex, pool_opts})
    %{name: name}
  end

  test "a role that no longer exists revokes the subscription", %{name: name} do
    :ok = Bier.Events.Registry.register_table(name, @table, "wal_recheck_dropped_role")
    :ok = Bier.Wal.notify_recheck(name)
    assert_receive {:bier_wal_recheck, :revoked}, 5_000
  end

  test "any other database error keeps the subscription", %{name: name} do
    # A NUL byte cannot be bound as a role name: Postgres refuses the
    # parameter itself (22021), a `Postgrex.Error` that is NOT a missing
    # role — standing in for any fault that says nothing about privileges.
    :ok = Bier.Events.Registry.register_table(name, @table, "wal_recheck\0role")
    :ok = Bier.Wal.notify_recheck(name)
    assert_receive {:bier_wal_recheck, :keep}, 5_000
  end
end
