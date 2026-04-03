defmodule Vor.Features.MinMaxTest do
  use ExUnit.Case

  test "max of two values" do
    source = """
    agent MaxTest do
      protocol do
        accepts {:compare, a: integer, b: integer}
        emits {:result, larger: integer}
      end

      on {:compare, a: A, b: B} do
        larger = max(A, B)
        emit {:result, larger: larger}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])
    assert {:result, %{larger: 10}} = GenServer.call(pid, {:compare, %{a: 3, b: 10}})
    assert {:result, %{larger: 7}} = GenServer.call(pid, {:compare, %{a: 7, b: 2}})
    assert {:result, %{larger: 5}} = GenServer.call(pid, {:compare, %{a: 5, b: 5}})
    GenServer.stop(pid)
  end

  test "min of two values" do
    source = """
    agent MinTest do
      protocol do
        accepts {:compare, a: integer, b: integer}
        emits {:result, smaller: integer}
      end

      on {:compare, a: A, b: B} do
        smaller = min(A, B)
        emit {:result, smaller: smaller}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])
    assert {:result, %{smaller: 3}} = GenServer.call(pid, {:compare, %{a: 3, b: 10}})
    assert {:result, %{smaller: 2}} = GenServer.call(pid, {:compare, %{a: 7, b: 2}})
    GenServer.stop(pid)
  end

  test "max in transition tracks high water mark" do
    source = """
    agent HighWater do
      state peak: integer

      protocol do
        accepts {:record, value: integer}
        accepts {:get_peak}
        emits {:ok}
        emits {:peak, value: integer}
      end

      on {:record, value: V} do
        transition peak: max(peak, V)
        emit {:ok}
      end

      on {:get_peak} do
        emit {:peak, value: peak}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])
    GenServer.call(pid, {:record, %{value: 5}})
    GenServer.call(pid, {:record, %{value: 15}})
    GenServer.call(pid, {:record, %{value: 8}})
    assert {:peak, %{value: 15}} = GenServer.call(pid, {:get_peak, %{}})
    GenServer.stop(pid)
  end

  test "max in gen_statem" do
    source = """
    agent StatemMax do
      state phase: :tracking | :done
      state high: integer

      protocol do
        accepts {:sample, value: integer}
        accepts {:finish}
        emits {:ok}
        emits {:peak, value: integer}
      end

      on {:sample, value: V} when phase == :tracking do
        transition high: max(high, V)
        emit {:ok}
      end

      on {:finish} when phase == :tracking do
        transition phase: :done
        emit {:peak, value: high}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = :gen_statem.start_link(result.module, [], [])
    :gen_statem.call(pid, {:sample, %{value: 5}})
    :gen_statem.call(pid, {:sample, %{value: 25}})
    :gen_statem.call(pid, {:sample, %{value: 12}})
    assert {:peak, %{value: 25}} = :gen_statem.call(pid, {:finish, %{}})
    :gen_statem.stop(pid)
  end
end
