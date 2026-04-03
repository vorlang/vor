defmodule Vor.Features.MapOperationsTest do
  use ExUnit.Case

  test "map_get with default" do
    source = """
    agent MapGet do
      state data: map

      protocol do
        accepts {:get, key: atom}
        emits {:value, v: integer}
      end

      on {:get, key: K} do
        v = map_get(data, K, 0)
        emit {:value, v: v}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])
    assert {:value, %{v: 0}} = GenServer.call(pid, {:get, %{key: :missing}})
    GenServer.stop(pid)
  end

  test "map_put and map_get round trip" do
    source = """
    agent MapPut do
      state data: map

      protocol do
        accepts {:put, key: atom, value: integer}
        accepts {:get, key: atom}
        emits {:ok}
        emits {:value, v: integer}
      end

      on {:put, key: K, value: V} do
        transition data: map_put(data, K, V)
        emit {:ok}
      end

      on {:get, key: K} do
        v = map_get(data, K, 0)
        emit {:value, v: v}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])
    GenServer.call(pid, {:put, %{key: :x, value: 42}})
    assert {:value, %{v: 42}} = GenServer.call(pid, {:get, %{key: :x}})
    assert {:value, %{v: 0}} = GenServer.call(pid, {:get, %{key: :y}})
    GenServer.stop(pid)
  end

  test "map_size returns entry count" do
    source = """
    agent MapSize do
      state data: map

      protocol do
        accepts {:put, key: atom, value: integer}
        accepts {:size}
        emits {:ok}
        emits {:count, n: integer}
      end

      on {:put, key: K, value: V} do
        transition data: map_put(data, K, V)
        emit {:ok}
      end

      on {:size} do
        n = map_size(data)
        emit {:count, n: n}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])
    assert {:count, %{n: 0}} = GenServer.call(pid, {:size, %{}})
    GenServer.call(pid, {:put, %{key: :a, value: 1}})
    GenServer.call(pid, {:put, %{key: :b, value: 2}})
    assert {:count, %{n: 2}} = GenServer.call(pid, {:size, %{}})
    GenServer.stop(pid)
  end

  test "map_sum returns sum of values" do
    source = """
    agent MapSum do
      state data: map

      protocol do
        accepts {:put, key: atom, value: integer}
        accepts {:total}
        emits {:ok}
        emits {:sum, value: integer}
      end

      on {:put, key: K, value: V} do
        transition data: map_put(data, K, V)
        emit {:ok}
      end

      on {:total} do
        t = map_sum(data)
        emit {:sum, value: t}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])
    GenServer.call(pid, {:put, %{key: :a, value: 10}})
    GenServer.call(pid, {:put, %{key: :b, value: 20}})
    GenServer.call(pid, {:put, %{key: :c, value: 30}})
    assert {:sum, %{value: 60}} = GenServer.call(pid, {:total, %{}})
    GenServer.stop(pid)
  end

  test "map_delete removes key" do
    source = """
    agent MapDelete do
      state data: map

      protocol do
        accepts {:put, key: atom, value: integer}
        accepts {:remove, key: atom}
        accepts {:size}
        emits {:ok}
        emits {:count, n: integer}
      end

      on {:put, key: K, value: V} do
        transition data: map_put(data, K, V)
        emit {:ok}
      end

      on {:remove, key: K} do
        transition data: map_delete(data, K)
        emit {:ok}
      end

      on {:size} do
        n = map_size(data)
        emit {:count, n: n}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])
    GenServer.call(pid, {:put, %{key: :a, value: 1}})
    GenServer.call(pid, {:put, %{key: :b, value: 2}})
    assert {:count, %{n: 2}} = GenServer.call(pid, {:size, %{}})
    GenServer.call(pid, {:remove, %{key: :a}})
    assert {:count, %{n: 1}} = GenServer.call(pid, {:size, %{}})
    GenServer.stop(pid)
  end

  test "map operations in gen_statem" do
    source = """
    agent StatemMap do
      state phase: :collecting | :done
      state data: map

      protocol do
        accepts {:add, key: atom, value: integer}
        accepts {:finish}
        emits {:ok}
        emits {:result, total: integer}
      end

      on {:add, key: K, value: V} when phase == :collecting do
        transition data: map_put(data, K, V)
        emit {:ok}
      end

      on {:finish} when phase == :collecting do
        total = map_sum(data)
        transition phase: :done
        emit {:result, total: total}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = :gen_statem.start_link(result.module, [], [])
    :gen_statem.call(pid, {:add, %{key: :a, value: 10}})
    :gen_statem.call(pid, {:add, %{key: :b, value: 20}})
    assert {:result, %{total: 30}} = :gen_statem.call(pid, {:finish, %{}})
    :gen_statem.stop(pid)
  end
end
