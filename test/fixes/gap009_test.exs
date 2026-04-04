defmodule Vor.Fixes.Gap009Test do
  use ExUnit.Case

  test "variable bound in if block visible to emit in same block" do
    source = """
    agent IfScope do
      state data: map

      protocol do
        accepts {:put, key: atom, value: integer}
        accepts {:get, key: atom}
        emits {:ok}
        emits {:found, value: integer}
        emits {:not_found}
      end

      on {:put, key: K, value: V} do
        transition data: map_put(data, K, V)
        emit {:ok}
      end

      on {:get, key: K} do
        has_key = map_has(data, K)
        if has_key == :true do
          value = map_get(data, K, 0)
          emit {:found, value: value}
        else
          emit {:not_found}
        end
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])

    GenServer.call(pid, {:put, %{key: :x, value: 42}})
    assert {:found, %{value: 42}} = GenServer.call(pid, {:get, %{key: :x}})
    assert {:not_found, %{}} = GenServer.call(pid, {:get, %{key: :y}})
    GenServer.stop(pid)
  end

  test "multiple variables bound in if block all visible" do
    source = """
    agent IfScopeMulti do
      state data: map

      protocol do
        accepts {:put, key: atom, value: integer}
        accepts {:analyze, key: atom}
        emits {:ok}
        emits {:analysis, value: integer, doubled: integer}
        emits {:missing}
      end

      on {:put, key: K, value: V} do
        transition data: map_put(data, K, V)
        emit {:ok}
      end

      on {:analyze, key: K} do
        has_key = map_has(data, K)
        if has_key == :true do
          value = map_get(data, K, 0)
          doubled = value + value
          emit {:analysis, value: value, doubled: doubled}
        else
          emit {:missing}
        end
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])

    GenServer.call(pid, {:put, %{key: :x, value: 7}})
    assert {:analysis, %{value: 7, doubled: 14}} = GenServer.call(pid, {:analyze, %{key: :x}})
    GenServer.stop(pid)
  end

  test "variable in if branch NOT visible in else (isolation)" do
    source = """
    agent IfScopeIsolation do
      protocol do
        accepts {:test, value: integer}
        emits {:positive, doubled: integer}
        emits {:negative}
      end

      on {:test, value: V} do
        if V > 0 do
          doubled = V + V
          emit {:positive, doubled: doubled}
        else
          emit {:negative}
        end
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])

    assert {:positive, %{doubled: 10}} = GenServer.call(pid, {:test, %{value: 5}})
    assert {:negative, %{}} = GenServer.call(pid, {:test, %{value: -3}})
    GenServer.stop(pid)
  end

  test "variable binding and transition in same if block" do
    source = """
    agent IfScopeTransition do
      state last_result: integer

      protocol do
        accepts {:process, value: integer}
        accepts {:get_last}
        emits {:result, computed: integer}
        emits {:skipped}
        emits {:last, value: integer}
      end

      on {:process, value: V} do
        if V > 0 do
          computed = V * V
          transition last_result: computed
          emit {:result, computed: computed}
        else
          emit {:skipped}
        end
      end

      on {:get_last} do
        emit {:last, value: last_result}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])

    assert {:result, %{computed: 25}} = GenServer.call(pid, {:process, %{value: 5}})
    assert {:last, %{value: 25}} = GenServer.call(pid, {:get_last, %{}})
    GenServer.stop(pid)
  end

  test "gen_statem variable scoping in if block" do
    source = """
    agent StatemIfScope do
      state phase: :active | :done
      state data: map

      protocol do
        accepts {:put, key: atom, value: integer}
        accepts {:lookup, key: atom}
        emits {:ok}
        emits {:found, value: integer}
        emits {:missing}
      end

      on {:put, key: K, value: V} when phase == :active do
        transition data: map_put(data, K, V)
        emit {:ok}
      end

      on {:lookup, key: K} when phase == :active do
        has_key = map_has(data, K)
        if has_key == :true do
          value = map_get(data, K, 0)
          emit {:found, value: value}
        else
          emit {:missing}
        end
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = :gen_statem.start_link(result.module, [], [])

    :gen_statem.call(pid, {:put, %{key: :x, value: 99}})
    assert {:found, %{value: 99}} = :gen_statem.call(pid, {:lookup, %{key: :x}})
    assert {:missing, %{}} = :gen_statem.call(pid, {:lookup, %{key: :y}})
    :gen_statem.stop(pid)
  end
end
