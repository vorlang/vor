defmodule Vor.Codegen.ConditionalTransitionsTest do
  use ExUnit.Case

  # --- Positive: conditional transitions work ---

  test "if/else with different transitions in each branch" do
    source = """
    agent ConditionalTransition do
      state phase: :idle | :high | :low
      state value: integer

      protocol do
        accepts {:set, n: integer}
        accepts {:get}
        emits {:ok}
        emits {:state, value: integer}
      end

      on {:set, n: N} when phase == :idle do
        transition value: N
        if N > 10 do
          transition phase: :high
        else
          transition phase: :low
        end
        emit {:ok}
      end

      on {:get} do
        emit {:state, value: value}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)

    # High path
    {:ok, pid1} = :gen_statem.start_link(result.module, [], [])
    :gen_statem.call(pid1, {:set, %{n: 20}})
    {state1, _} = :sys.get_state(pid1)
    assert state1 == :high
    assert {:state, %{value: 20}} = :gen_statem.call(pid1, {:get, %{}})
    :gen_statem.stop(pid1)

    # Low path
    {:ok, pid2} = :gen_statem.start_link(result.module, [], [])
    :gen_statem.call(pid2, {:set, %{n: 3}})
    {state2, _} = :sys.get_state(pid2)
    assert state2 == :low
    assert {:state, %{value: 3}} = :gen_statem.call(pid2, {:get, %{}})
    :gen_statem.stop(pid2)
  end

  test "transitions before and inside if/else all take effect" do
    source = """
    agent MixedTransitions do
      state phase: :idle | :active | :special
      state count: integer
      state tag: atom

      protocol do
        accepts {:process, n: integer}
        accepts {:get}
        emits {:ok}
        emits {:info, count: integer, tag: atom}
      end

      on {:process, n: N} when phase == :idle do
        transition count: count + 1
        transition tag: :processed
        if N > 100 do
          transition phase: :special
        else
          transition phase: :active
        end
        emit {:ok}
      end

      on {:get} do
        emit {:info, count: count, tag: tag}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)

    {:ok, pid1} = :gen_statem.start_link(result.module, [], [])
    :gen_statem.call(pid1, {:process, %{n: 200}})
    {state1, _} = :sys.get_state(pid1)
    assert state1 == :special
    assert {:info, %{count: 1, tag: :processed}} = :gen_statem.call(pid1, {:get, %{}})
    :gen_statem.stop(pid1)

    {:ok, pid2} = :gen_statem.start_link(result.module, [], [])
    :gen_statem.call(pid2, {:process, %{n: 5}})
    {state2, _} = :sys.get_state(pid2)
    assert state2 == :active
    assert {:info, %{count: 1, tag: :processed}} = :gen_statem.call(pid2, {:get, %{}})
    :gen_statem.stop(pid2)
  end

  # --- Negative: cast handler with conditional transition, no emit ---

  test "cast handler with conditional transition compiles" do
    source = """
    agent CastConditional do
      state phase: :idle | :high | :low
      state value: integer

      protocol do
        accepts {:set, n: integer}
      end

      on {:set, n: N} when phase == :idle do
        transition value: N
        if N > 10 do
          transition phase: :high
        else
          transition phase: :low
        end
      end
    end
    """

    {:ok, _result} = Vor.Compiler.compile_string(source)
  end

  # --- Runtime: send/broadcast read post-transition data ---

  test "send reads post-transition values" do
    source = """
    agent PostTransitionSend do
      state phase: :idle | :active
      state counter: integer

      protocol do
        accepts {:go}
        sends {:notification, count: integer}
        emits {:ok}
      end

      on {:go} when phase == :idle do
        transition counter: counter + 1
        transition phase: :active
        send :listener {:notification, count: counter}
        emit {:ok}
      end
    end

    agent Listener do
      state heard: integer

      protocol do
        accepts {:notification, count: integer}
        accepts {:check}
        emits {:heard, value: integer}
      end

      on {:notification, count: C} do
        transition heard: C
      end

      on {:check} do
        emit {:heard, value: heard}
      end
    end

    system PostTransSendTest do
      agent :sender, PostTransitionSend()
      agent :listener, Listener()
      connect :sender -> :listener
    end
    """

    {:ok, result} = Vor.Compiler.compile_system_and_load(source)
    {:ok, sup_pid} = result.system.start_link.()

    registry = result.system.registry
    [{pid, _}] = Registry.lookup(registry, :sender)
    GenServer.call(pid, {:go, %{}})

    Process.sleep(100)

    [{lpid, _}] = Registry.lookup(registry, :listener)
    # counter was 0, transition sets it to 1, send reads post-transition value = 1
    assert {:heard, %{value: 1}} = GenServer.call(lpid, {:check, %{}})

    Supervisor.stop(sup_pid)
  end

  # --- Backward compat ---

  test "handlers without conditionals still work" do
    source = """
    agent Simple do
      state phase: :a | :b

      protocol do
        accepts {:go}
        emits {:ok}
      end

      on {:go} when phase == :a do
        transition phase: :b
        emit {:ok}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = :gen_statem.start_link(result.module, [], [])
    assert {:ok, %{}} = :gen_statem.call(pid, {:go, %{}})
    {state, _} = :sys.get_state(pid)
    assert state == :b
    :gen_statem.stop(pid)
  end
end
