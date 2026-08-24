defmodule Bier.Wal.BufferTest do
  use ExUnit.Case, async: true

  alias Bier.Wal.Buffer

  @orders {"api", "orders"}
  @items {"api", "items"}

  defp start!(buffer_size) do
    name = :"buffer_test_#{System.unique_integer([:positive])}"
    conf = struct!(Bier.Config, name: name, events_buffer_size: buffer_size)
    start_supervised!({Buffer, conf})
    gen = Buffer.new_generation(name)
    {name, gen}
  end

  defp cursor(lo, seq \\ 0), do: {{0, lo}, seq}
  defp event(n), do: %{kind: :insert, n: n}

  test "replays events strictly after the cursor, across tables, in order" do
    {name, gen} = start!(10)

    :ok = Buffer.append(name, [{cursor(1), @orders, event(1)}, {cursor(1, 1), @items, event(2)}])
    :ok = Buffer.append(name, [{cursor(2), @orders, event(3)}])

    assert {:ok, replayed} = Buffer.replay_after(name, [@orders, @items], cursor(1), gen)

    assert Enum.map(replayed, fn {c, _t, e} -> {c, e.n} end) == [
             {cursor(1, 1), 2},
             {cursor(2), 3}
           ]
  end

  test "a cursor older than a wrapped table's history resets" do
    {name, gen} = start!(2)

    for n <- 1..4, do: Buffer.append(name, [{cursor(n), @orders, event(n)}])

    # Buffer holds cursors 3 and 4; cursor 1 predates retained history.
    assert Buffer.replay_after(name, [@orders], cursor(1), gen) == :reset
    assert {:ok, [_]} = Buffer.replay_after(name, [@orders], cursor(3), gen)
  end

  test "an empty table never forces a reset" do
    {name, gen} = start!(2)
    assert {:ok, []} = Buffer.replay_after(name, [@items], cursor(1), gen)
  end

  test "generation mismatch resets and new_generation clears history" do
    {name, gen} = start!(10)
    :ok = Buffer.append(name, [{cursor(1), @orders, event(1)}])

    assert Buffer.replay_after(name, [@orders], cursor(0), gen - 1) == :reset

    new_gen = Buffer.new_generation(name)
    assert new_gen == gen + 1
    assert {:ok, []} = Buffer.replay_after(name, [@orders], cursor(0), new_gen)
  end

  test "drop clears only the given tables" do
    {name, gen} = start!(10)
    :ok = Buffer.append(name, [{cursor(1), @orders, event(1)}, {cursor(1, 1), @items, event(2)}])
    :ok = Buffer.drop(name, [@orders])

    assert {:ok, replayed} = Buffer.replay_after(name, [@orders, @items], cursor(0), gen)
    assert Enum.map(replayed, fn {_c, t, _e} -> t end) == [@items]
  end
end
