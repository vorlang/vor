defmodule Vor.Examples.LivenessTest do
  use ExUnit.Case

  test "stuck agent rescued by liveness timeout" do
    source = """
    agent StuckWorker do
      state phase: :idle | :working | :done

      protocol do
        accepts {:start, id: term}
        emits {:ok, id: term}
      end

      on {:start, id: I} when phase == :idle do
        transition phase: :working
      end

      liveness "finishes work" monitored(within: 200) do
        always(phase != :idle implies eventually(phase == :done))
      end

      resilience do
        on_invariant_violation("finishes work") ->
          transition phase: :done
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = :gen_statem.start_link(result.module, [], [])

    # Start work but never send finish
    :gen_statem.cast(pid, {:start, %{id: 1}})
    Process.sleep(10)
    assert {:working, _} = :sys.get_state(pid)

    # Wait for timeout to fire (200ms + buffer)
    Process.sleep(300)

    # Agent should be rescued to :done
    assert {:done, _} = :sys.get_state(pid)
    assert Process.alive?(pid)
  end

  test "agent that completes normally never triggers timeout" do
    source = """
    agent QuickWorker do
      state phase: :idle | :working | :done

      protocol do
        accepts {:start, id: term}
        accepts {:finish, id: term}
        emits {:ok, id: term}
      end

      on {:start, id: I} when phase == :idle do
        transition phase: :working
      end

      on {:finish, id: I} when phase == :working do
        transition phase: :done
      end

      liveness "finishes work" monitored(within: 500) do
        always(phase != :idle implies eventually(phase == :done))
      end

      resilience do
        on_invariant_violation("finishes work") ->
          transition phase: :done
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = :gen_statem.start_link(result.module, [], [])

    :gen_statem.cast(pid, {:start, %{id: 1}})
    Process.sleep(10)
    :gen_statem.cast(pid, {:finish, %{id: 1}})
    Process.sleep(10)

    assert {:done, _} = :sys.get_state(pid)

    # Wait past timeout — should not crash or change state
    Process.sleep(600)
    assert {:done, _} = :sys.get_state(pid)
    assert Process.alive?(pid)
  end

  test "timeout resets on intermediate transitions" do
    source = """
    agent MultiStep do
      state phase: :idle | :step1 | :step2 | :done

      protocol do
        accepts {:begin, id: term}
        accepts {:advance, id: term}
        accepts {:complete, id: term}
        emits {:ok, id: term}
      end

      on {:begin, id: I} when phase == :idle do
        transition phase: :step1
      end

      on {:advance, id: I} when phase == :step1 do
        transition phase: :step2
      end

      on {:complete, id: I} when phase == :step2 do
        transition phase: :done
      end

      liveness "completes" monitored(within: 300) do
        always(phase != :idle implies eventually(phase == :done))
      end

      resilience do
        on_invariant_violation("completes") ->
          transition phase: :done
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = :gen_statem.start_link(result.module, [], [])

    :gen_statem.cast(pid, {:begin, %{id: 1}})
    Process.sleep(200)

    # Advance resets the timeout
    :gen_statem.cast(pid, {:advance, %{id: 1}})
    Process.sleep(200)

    # Complete before new timeout fires
    :gen_statem.cast(pid, {:complete, %{id: 1}})
    Process.sleep(10)

    assert {:done, _} = :sys.get_state(pid)
  end

  test "parameterized timeout duration" do
    source = """
    agent ConfigWorker(timeout_ms: integer) do
      state phase: :idle | :working | :done

      protocol do
        accepts {:start, id: term}
        emits {:ok, id: term}
      end

      on {:start, id: I} when phase == :idle do
        transition phase: :working
      end

      liveness "finishes" monitored(within: timeout_ms) do
        always(phase != :idle implies eventually(phase == :done))
      end

      resilience do
        on_invariant_violation("finishes") ->
          transition phase: :done
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)

    # Short timeout — should fire quickly
    {:ok, pid} = :gen_statem.start_link(result.module, [timeout_ms: 150], [])
    :gen_statem.cast(pid, {:start, %{id: 1}})
    Process.sleep(300)
    assert {:done, _} = :sys.get_state(pid)
    :gen_statem.stop(pid)

    # Long timeout — should not fire during test
    {:ok, pid2} = :gen_statem.start_link(result.module, [timeout_ms: 10_000], [])
    :gen_statem.cast(pid2, {:start, %{id: 2}})
    Process.sleep(200)
    assert {:working, _} = :sys.get_state(pid2)
    :gen_statem.stop(pid2)
  end

  test "timeout transitions appear in state graph" do
    source = """
    agent GraphWorker do
      state phase: :idle | :active | :done

      protocol do
        accepts {:start, id: term}
        emits {:ok, id: term}
      end

      on {:start, id: I} when phase == :idle do
        transition phase: :active
      end

      liveness "completes" monitored(within: 5000) do
        always(phase != :idle implies eventually(phase == :done))
      end

      resilience do
        on_invariant_violation("completes") ->
          transition phase: :done
      end
    end
    """

    {:ok, graph} = Vor.Compiler.extract_graph(source)

    # Regular transition
    assert Enum.any?(graph.transitions, fn t ->
      t.from == :idle and t.to == :active
    end)

    # Timeout transition
    assert Enum.any?(graph.transitions, fn t ->
      t.from == :active and t.to == :done and t.trigger == :state_timeout
    end)

    # Mermaid should include it
    mermaid = Vor.Graph.to_mermaid(graph)
    assert String.contains?(mermaid, "active --> done")
  end

  test "agent with no liveness invariants compiles normally" do
    source = """
    agent NoLiveness do
      state phase: :a | :b

      protocol do
        accepts {:go, id: term}
        emits {:ok, id: term}
      end

      on {:go, id: I} when phase == :a do
        transition phase: :b
      end
    end
    """

    {:ok, _result} = Vor.Compiler.compile_string(source)
  end
end
