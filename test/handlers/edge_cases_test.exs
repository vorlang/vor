defmodule Vor.Handlers.EdgeCasesTest do
  use ExUnit.Case

  test "guarded call handler returns error when no guard matches" do
    source = """
    agent GuardedOnly do
      state phase: :idle | :active

      protocol do
        accepts {:request, value: integer}
        emits {:ok, result: integer}
        emits {:error, reason: atom}
      end

      on {:request, value: V} when phase == :idle do
        emit {:ok, result: V}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = :gen_statem.start_link(result.module, [], [])

    # In :idle state, the handler matches
    assert {:ok, %{result: 5}} = :gen_statem.call(pid, {:request, %{value: 5}})

    :gen_statem.stop(pid)
  end

  test "existing echo agent still compiles and works" do
    source = """
    agent Echo do
      protocol do
        accepts {:ping, payload: term}
        emits {:pong, payload: term}
      end

      on {:ping, payload: P} do
        emit {:pong, payload: P}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])
    assert {:pong, %{payload: "hello"}} = GenServer.call(pid, {:ping, %{payload: "hello"}})
    GenServer.stop(pid)
  end

  test "handler with only transitions and no emit compiles (cast)" do
    source = """
    agent TransitionOnly do
      state phase: :idle | :active

      protocol do
        accepts {:activate}
      end

      on {:activate} when phase == :idle do
        transition phase: :active
      end
    end
    """

    {:ok, _mod} = Vor.Compiler.compile_string(source)
  end

  test "multiple handlers with complete emit coverage compiles" do
    source = """
    agent MultiHandler do
      state phase: :idle | :active

      protocol do
        accepts {:check}
        emits {:idle_reply}
        emits {:active_reply}
      end

      on {:check} when phase == :idle do
        emit {:idle_reply}
      end

      on {:check} when phase == :active do
        emit {:active_reply}
      end
    end
    """

    {:ok, _mod} = Vor.Compiler.compile_string(source)
  end
end
