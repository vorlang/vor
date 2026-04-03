defmodule Vor.Features.LwwMergeTest do
  use ExUnit.Case

  defp compile_lww_agent do
    source = """
    agent LWWStore do
      state store: map

      protocol do
        accepts {:set, key: atom, entry: map}
        accepts {:merge, remote: map}
        accepts {:get, key: atom}
        emits {:ok}
        emits {:value, entry: map}
      end

      on {:set, key: K, entry: E} do
        transition store: map_put(store, K, E)
        emit {:ok}
      end

      on {:merge, remote: R} do
        transition store: map_merge(store, R, :lww)
        emit {:ok}
      end

      on {:get, key: K} do
        entry = map_get(store, K, :missing)
        emit {:value, entry: entry}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])
    pid
  end

  test "lww keeps higher timestamp (remote wins)" do
    pid = compile_lww_agent()

    local = %{value: :local, timestamp: 100, node_id: :node1}
    GenServer.call(pid, {:set, %{key: :x, entry: local}})

    remote = %{x: %{value: :remote, timestamp: 200, node_id: :node2}}
    GenServer.call(pid, {:merge, %{remote: remote}})

    {:value, %{entry: entry}} = GenServer.call(pid, {:get, %{key: :x}})
    assert entry.value == :remote
    assert entry.timestamp == 200
    GenServer.stop(pid)
  end

  test "lww keeps higher timestamp (local wins)" do
    pid = compile_lww_agent()

    local = %{value: :local, timestamp: 300, node_id: :node1}
    GenServer.call(pid, {:set, %{key: :x, entry: local}})

    remote = %{x: %{value: :remote, timestamp: 100, node_id: :node2}}
    GenServer.call(pid, {:merge, %{remote: remote}})

    {:value, %{entry: entry}} = GenServer.call(pid, {:get, %{key: :x}})
    assert entry.value == :local
    assert entry.timestamp == 300
    GenServer.stop(pid)
  end

  test "lww tiebreaks by node_id" do
    pid = compile_lww_agent()

    local = %{value: :from_node1, timestamp: 100, node_id: :node1}
    GenServer.call(pid, {:set, %{key: :x, entry: local}})

    remote = %{x: %{value: :from_node2, timestamp: 100, node_id: :node2}}
    GenServer.call(pid, {:merge, %{remote: remote}})

    {:value, %{entry: entry}} = GenServer.call(pid, {:get, %{key: :x}})
    # node2 > node1 lexicographically, so node2 wins
    assert entry.value == :from_node2
    GenServer.stop(pid)
  end

  test "lww adds new keys from remote" do
    pid = compile_lww_agent()

    GenServer.call(pid, {:set, %{key: :x, entry: %{value: 1, timestamp: 100, node_id: :n1}}})

    remote = %{y: %{value: 2, timestamp: 50, node_id: :n2}}
    GenServer.call(pid, {:merge, %{remote: remote}})

    {:value, %{entry: ex}} = GenServer.call(pid, {:get, %{key: :x}})
    assert ex.value == 1
    {:value, %{entry: ey}} = GenServer.call(pid, {:get, %{key: :y}})
    assert ey.value == 2
    GenServer.stop(pid)
  end

  test "lww is idempotent" do
    pid = compile_lww_agent()

    remote = %{x: %{value: :hello, timestamp: 100, node_id: :n1}}
    GenServer.call(pid, {:merge, %{remote: remote}})
    GenServer.call(pid, {:merge, %{remote: remote}})
    GenServer.call(pid, {:merge, %{remote: remote}})

    {:value, %{entry: entry}} = GenServer.call(pid, {:get, %{key: :x}})
    assert entry.value == :hello
    assert entry.timestamp == 100
    GenServer.stop(pid)
  end

  test "existing :max strategy still works" do
    source = """
    agent MaxStillWorks do
      state counts: map

      protocol do
        accepts {:set, key: atom, value: integer}
        accepts {:merge, remote: map}
        accepts {:get, key: atom}
        emits {:ok}
        emits {:value, v: integer}
      end

      on {:set, key: K, value: V} do
        transition counts: map_put(counts, K, V)
        emit {:ok}
      end

      on {:merge, remote: R} do
        transition counts: map_merge(counts, R, :max)
        emit {:ok}
      end

      on {:get, key: K} do
        v = map_get(counts, K, 0)
        emit {:value, v: v}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])
    GenServer.call(pid, {:set, %{key: :a, value: 5}})
    GenServer.call(pid, {:merge, %{remote: %{a: 3, b: 10}}})
    assert {:value, %{v: 5}} = GenServer.call(pid, {:get, %{key: :a}})
    assert {:value, %{v: 10}} = GenServer.call(pid, {:get, %{key: :b}})
    GenServer.stop(pid)
  end
end
