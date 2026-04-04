defmodule Vor.Fixes.Gap006Test do
  use ExUnit.Case

  test "Erlang module extern call works" do
    source = """
    agent ErlangExtern do
      extern do
        Erlang.erlang.system_time(unit: atom) :: integer
      end

      protocol do
        accepts {:now}
        emits {:time, value: integer}
      end

      on {:now} do
        t = Erlang.erlang.system_time(unit: :millisecond)
        emit {:time, value: t}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])
    {:time, %{value: t}} = GenServer.call(pid, {:now, %{}})
    assert is_integer(t)
    assert t > 1_000_000_000_000
    GenServer.stop(pid)
  end

  test "Erlang.lists module works" do
    source = """
    agent ErlangLists do
      extern do
        Erlang.lists.sort(list: list) :: list
      end

      protocol do
        accepts {:sort, items: list}
        emits {:sorted, result: list}
      end

      on {:sort, items: I} do
        result = Erlang.lists.sort(list: I)
        emit {:sorted, result: result}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])
    {:sorted, %{result: r}} = GenServer.call(pid, {:sort, %{items: [3, 1, 2]}})
    assert r == [1, 2, 3]
    GenServer.stop(pid)
  end

  test "Elixir module extern calls still work" do
    source = """
    agent ElixirExtern do
      extern do
        Vor.TestHelpers.Echo.reflect(value: term) :: term
      end

      protocol do
        accepts {:echo, msg: term}
        emits {:result, value: term}
      end

      on {:echo, msg: M} do
        result = Vor.TestHelpers.Echo.reflect(value: M)
        emit {:result, value: result}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])
    assert {:result, %{value: :hello}} = GenServer.call(pid, {:echo, %{msg: :hello}})
    GenServer.stop(pid)
  end
end
