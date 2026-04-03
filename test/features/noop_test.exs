defmodule Vor.Features.NoopTest do
  use ExUnit.Case

  test "noop in cast handler compiles and runs" do
    source = """
    agent NoopCast do
      state phase: :idle | :active

      protocol do
        accepts {:ignore_me}
        accepts {:go}
        emits {:ok}
      end

      on {:ignore_me} when phase == :idle do
        noop
      end

      on {:go} when phase == :idle do
        transition phase: :active
        emit {:ok}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = :gen_statem.start_link(result.module, [], [])

    :gen_statem.cast(pid, {:ignore_me, %{}})
    Process.sleep(50)

    assert {:ok, %{}} = :gen_statem.call(pid, {:go, %{}})
    :gen_statem.stop(pid)
  end

  test "noop in gen_server cast handler compiles" do
    source = """
    agent GenServerNoop do
      state count: integer

      protocol do
        accepts {:skip}
        accepts {:get}
        emits {:count, value: integer}
      end

      on {:skip} do
        noop
      end

      on {:get} do
        emit {:count, value: count}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])

    GenServer.cast(pid, {:skip, %{}})
    Process.sleep(50)

    assert {:count, %{value: 0}} = GenServer.call(pid, {:get, %{}})
    GenServer.stop(pid)
  end

  test "noop in if/else branch" do
    source = """
    agent NoopBranch do
      state phase: :idle | :done
      state count: integer

      protocol do
        accepts {:process, important: atom}
        emits {:ok}
      end

      on {:process, important: I} when phase == :idle do
        if I == :yes do
          transition count: count + 1
          transition phase: :done
        else
          noop
        end
        emit {:ok}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = :gen_statem.start_link(result.module, [], [])

    :gen_statem.call(pid, {:process, %{important: :no}})
    {state, data} = :sys.get_state(pid)
    assert state == :idle
    assert data.count == 0
    :gen_statem.stop(pid)
  end
end
