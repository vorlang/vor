defmodule Vor.Examples.PNCounterNativeTest do
  use ExUnit.Case

  @pn_source """
  agent PNCounter(node_id: atom) do
    state counter: map

    protocol do
      accepts {:increment}
      accepts {:decrement}
      accepts {:merge, remote: map}
      accepts {:value}
      accepts {:get_state}
      emits {:ok}
      emits {:count, value: integer}
      emits {:state, counter: map}
    end

    on :init do
      p = map_put(counter, node_id, 0)
      n = map_put(counter, node_id, 0)
      with_p = map_put(counter, :p, p)
      initial = map_put(with_p, :n, n)
      transition counter: initial
    end

    on {:increment} do
      p = map_get(counter, :p, counter)
      current = map_get(p, node_id, 0)
      new_p = map_put(p, node_id, current + 1)
      transition counter: map_put(counter, :p, new_p)
      emit {:ok}
    end

    on {:decrement} do
      n = map_get(counter, :n, counter)
      current = map_get(n, node_id, 0)
      new_n = map_put(n, node_id, current + 1)
      transition counter: map_put(counter, :n, new_n)
      emit {:ok}
    end

    on {:merge, remote: R} do
      local_p = map_get(counter, :p, counter)
      remote_p = map_get(R, :p, R)
      merged_p = map_merge(local_p, remote_p, :max)

      local_n = map_get(counter, :n, counter)
      remote_n = map_get(R, :n, R)
      merged_n = map_merge(local_n, remote_n, :max)

      with_p = map_put(counter, :p, merged_p)
      new_counter = map_put(with_p, :n, merged_n)
      transition counter: new_counter
      emit {:ok}
    end

    on {:value} do
      p = map_get(counter, :p, counter)
      n = map_get(counter, :n, counter)
      p_sum = map_sum(p)
      n_sum = map_sum(n)
      emit {:count, value: p_sum - n_sum}
    end

    on {:get_state} do
      emit {:state, counter: counter}
    end
  end
  """

  test "PN-Counter compiles" do
    {:ok, _} = Vor.Compiler.compile_string(@pn_source)
  end

  test "basic increment and decrement" do
    {:ok, result} = Vor.Compiler.compile_and_load(@pn_source)
    {:ok, pid} = GenServer.start_link(result.module, [node_id: :node1])

    for _ <- 1..3, do: GenServer.call(pid, {:increment, %{}})
    assert {:count, %{value: 3}} = GenServer.call(pid, {:value, %{}})

    GenServer.call(pid, {:decrement, %{}})
    assert {:count, %{value: 2}} = GenServer.call(pid, {:value, %{}})

    GenServer.stop(pid)
  end

  test "two-node merge produces correct combined value" do
    {:ok, result} = Vor.Compiler.compile_and_load(@pn_source)

    {:ok, pid1} = GenServer.start_link(result.module, [node_id: :node1])
    {:ok, pid2} = GenServer.start_link(result.module, [node_id: :node2])

    for _ <- 1..5, do: GenServer.call(pid1, {:increment, %{}})
    for _ <- 1..3, do: GenServer.call(pid2, {:increment, %{}})
    GenServer.call(pid2, {:decrement, %{}})

    assert {:count, %{value: 5}} = GenServer.call(pid1, {:value, %{}})
    assert {:count, %{value: 2}} = GenServer.call(pid2, {:value, %{}})

    # Merge node2 into node1
    {:state, %{counter: s2}} = GenServer.call(pid2, {:get_state, %{}})
    GenServer.call(pid1, {:merge, %{remote: s2}})
    assert {:count, %{value: 7}} = GenServer.call(pid1, {:value, %{}})

    # Merge node1 into node2 — both converge
    {:state, %{counter: s1}} = GenServer.call(pid1, {:get_state, %{}})
    GenServer.call(pid2, {:merge, %{remote: s1}})
    assert {:count, %{value: 7}} = GenServer.call(pid2, {:value, %{}})

    GenServer.stop(pid1)
    GenServer.stop(pid2)
  end

  test "merge is commutative — different orders produce same result" do
    {:ok, result} = Vor.Compiler.compile_and_load(@pn_source)

    {:ok, a} = GenServer.start_link(result.module, [node_id: :a])
    {:ok, b} = GenServer.start_link(result.module, [node_id: :b])
    {:ok, c} = GenServer.start_link(result.module, [node_id: :c])

    for _ <- 1..3, do: GenServer.call(a, {:increment, %{}})
    for _ <- 1..2, do: GenServer.call(b, {:increment, %{}})
    GenServer.call(b, {:decrement, %{}})
    for _ <- 1..4, do: GenServer.call(c, {:decrement, %{}})

    {:state, %{counter: sa}} = GenServer.call(a, {:get_state, %{}})
    {:state, %{counter: sb}} = GenServer.call(b, {:get_state, %{}})
    {:state, %{counter: sc}} = GenServer.call(c, {:get_state, %{}})

    # Order 1: a, b, c
    {:ok, r1} = GenServer.start_link(result.module, [node_id: :r1])
    GenServer.call(r1, {:merge, %{remote: sa}})
    GenServer.call(r1, {:merge, %{remote: sb}})
    GenServer.call(r1, {:merge, %{remote: sc}})
    {:count, %{value: v1}} = GenServer.call(r1, {:value, %{}})

    # Order 2: c, a, b
    {:ok, r2} = GenServer.start_link(result.module, [node_id: :r2])
    GenServer.call(r2, {:merge, %{remote: sc}})
    GenServer.call(r2, {:merge, %{remote: sa}})
    GenServer.call(r2, {:merge, %{remote: sb}})
    {:count, %{value: v2}} = GenServer.call(r2, {:value, %{}})

    assert v1 == v2
    # 3 + 2 - 1 - 4 = 0
    assert v1 == 0

    Enum.each([a, b, c, r1, r2], &GenServer.stop/1)
  end

  test "merge is idempotent" do
    {:ok, result} = Vor.Compiler.compile_and_load(@pn_source)

    {:ok, a} = GenServer.start_link(result.module, [node_id: :a])
    {:ok, b} = GenServer.start_link(result.module, [node_id: :b])

    for _ <- 1..5, do: GenServer.call(a, {:increment, %{}})
    for _ <- 1..3, do: GenServer.call(b, {:increment, %{}})

    {:state, %{counter: sb}} = GenServer.call(b, {:get_state, %{}})

    GenServer.call(a, {:merge, %{remote: sb}})
    {:count, %{value: v1}} = GenServer.call(a, {:value, %{}})
    GenServer.call(a, {:merge, %{remote: sb}})
    {:count, %{value: v2}} = GenServer.call(a, {:value, %{}})
    GenServer.call(a, {:merge, %{remote: sb}})
    {:count, %{value: v3}} = GenServer.call(a, {:value, %{}})

    assert v1 == 8
    assert v2 == 8
    assert v3 == 8

    GenServer.stop(a)
    GenServer.stop(b)
  end
end
