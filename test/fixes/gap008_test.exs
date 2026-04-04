defmodule Vor.Fixes.Gap008Test do
  use ExUnit.Case

  test "map_get with atom key" do
    source = """
    agent AtomKey do
      state data: map

      protocol do
        accepts {:put, entry: map}
        accepts {:get_value}
        emits {:ok}
        emits {:result, value: term}
      end

      on {:put, entry: E} do
        transition data: E
        emit {:ok}
      end

      on {:get_value} do
        v = map_get(data, :value, :missing)
        emit {:result, value: v}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])
    GenServer.call(pid, {:put, %{entry: %{value: 42, other: :stuff}}})
    assert {:result, %{value: 42}} = GenServer.call(pid, {:get_value, %{}})
    GenServer.stop(pid)
  end

  test "map_get with atom default" do
    source = """
    agent AtomDefault do
      state data: map

      protocol do
        accepts {:get, key: atom}
        emits {:result, value: term}
      end

      on {:get, key: K} do
        v = map_get(data, K, :not_found)
        emit {:result, value: v}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])
    assert {:result, %{value: :not_found}} = GenServer.call(pid, {:get, %{key: :x}})
    GenServer.stop(pid)
  end

  test "map_get with nil default" do
    source = """
    agent NilDefault do
      state data: map

      protocol do
        accepts {:get, key: atom}
        emits {:result, value: term}
      end

      on {:get, key: K} do
        v = map_get(data, K, nil)
        emit {:result, value: v}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])
    assert {:result, %{value: nil}} = GenServer.call(pid, {:get, %{key: :missing}})
    GenServer.stop(pid)
  end

  test "map_put with atom key" do
    source = """
    agent AtomPut do
      state data: map

      protocol do
        accepts {:set, value: integer}
        accepts {:get}
        emits {:ok}
        emits {:result, value: term}
      end

      on {:set, value: V} do
        transition data: map_put(data, :count, V)
        emit {:ok}
      end

      on {:get} do
        v = map_get(data, :count, 0)
        emit {:result, value: v}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])
    GenServer.call(pid, {:set, %{value: 99}})
    assert {:result, %{value: 99}} = GenServer.call(pid, {:get, %{}})
    GenServer.stop(pid)
  end

  test "map_has with atom key" do
    source = """
    agent AtomHas do
      state data: map

      protocol do
        accepts {:put, value: integer}
        accepts {:check}
        emits {:ok}
        emits {:result, exists: atom}
      end

      on {:put, value: V} do
        transition data: map_put(data, :key, V)
        emit {:ok}
      end

      on {:check} do
        exists = map_has(data, :key)
        emit {:result, exists: exists}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])
    assert {:result, %{exists: false}} = GenServer.call(pid, {:check, %{}})
    GenServer.call(pid, {:put, %{value: 1}})
    assert {:result, %{exists: true}} = GenServer.call(pid, {:check, %{}})
    GenServer.stop(pid)
  end

  test "map_delete with atom key" do
    source = """
    agent AtomDelete do
      state data: map

      protocol do
        accepts {:put, value: integer}
        accepts {:remove}
        accepts {:check}
        emits {:ok}
        emits {:result, exists: atom}
      end

      on {:put, value: V} do
        transition data: map_put(data, :key, V)
        emit {:ok}
      end

      on {:remove} do
        transition data: map_delete(data, :key)
        emit {:ok}
      end

      on {:check} do
        exists = map_has(data, :key)
        emit {:result, exists: exists}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])
    GenServer.call(pid, {:put, %{value: 1}})
    assert {:result, %{exists: true}} = GenServer.call(pid, {:check, %{}})
    GenServer.call(pid, {:remove, %{}})
    assert {:result, %{exists: false}} = GenServer.call(pid, {:check, %{}})
    GenServer.stop(pid)
  end
end
