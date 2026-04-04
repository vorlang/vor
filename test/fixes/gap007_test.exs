defmodule Vor.Fixes.Gap007Test do
  use ExUnit.Case

  test "extern call reads post-transition state field value" do
    source = """
    agent PostTransExtern do
      extern do
        Vor.TestHelpers.Echo.reflect(value: term) :: term
      end

      state count: integer

      protocol do
        accepts {:update_and_read}
        emits {:result, value: term}
      end

      on {:update_and_read} do
        transition count: count + 10
        reflected = Vor.TestHelpers.Echo.reflect(value: count)
        emit {:result, value: reflected}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])

    assert {:result, %{value: 10}} = GenServer.call(pid, {:update_and_read, %{}})
    GenServer.stop(pid)
  end

  test "extern call reads post-transition map state" do
    source = """
    agent PostTransMap do
      extern do
        Vor.TestHelpers.Echo.reflect(value: term) :: term
      end

      state data: map

      protocol do
        accepts {:set_and_read, key: atom, value: integer}
        emits {:result, echoed: term}
      end

      on {:set_and_read, key: K, value: V} do
        transition data: map_put(data, K, V)
        echoed = Vor.TestHelpers.Echo.reflect(value: data)
        emit {:result, echoed: echoed}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])

    assert {:result, %{echoed: %{x: 42}}} = GenServer.call(pid, {:set_and_read, %{key: :x, value: 42}})
    GenServer.stop(pid)
  end

  test "multiple transitions then extern reads final state" do
    source = """
    agent MultiTransExtern do
      extern do
        Vor.TestHelpers.Echo.reflect(value: term) :: term
      end

      state a: integer
      state b: integer

      protocol do
        accepts {:go}
        emits {:result, echoed_a: term, echoed_b: term}
      end

      on {:go} do
        transition a: a + 1
        transition b: b + 100
        ea = Vor.TestHelpers.Echo.reflect(value: a)
        eb = Vor.TestHelpers.Echo.reflect(value: b)
        emit {:result, echoed_a: ea, echoed_b: eb}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])

    assert {:result, %{echoed_a: 1, echoed_b: 100}} = GenServer.call(pid, {:go, %{}})
    GenServer.stop(pid)
  end

  test "extern in gen_statem reads post-transition data fields" do
    source = """
    agent StatemPostTrans do
      extern do
        Vor.TestHelpers.Echo.reflect(value: term) :: term
      end

      state phase: :idle | :done
      state count: integer

      protocol do
        accepts {:go}
        emits {:result, echoed: term}
      end

      on {:go} when phase == :idle do
        transition count: 42
        transition phase: :done
        echoed = Vor.TestHelpers.Echo.reflect(value: count)
        emit {:result, echoed: echoed}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = :gen_statem.start_link(result.module, [], [])

    assert {:result, %{echoed: 42}} = :gen_statem.call(pid, {:go, %{}})
    :gen_statem.stop(pid)
  end
end
