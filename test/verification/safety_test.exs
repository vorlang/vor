defmodule Vor.Verification.SafetyTest do
  use ExUnit.Case

  test "circuit breaker passes safety verification" do
    source = File.read!("examples/circuit_breaker.vor")
    {:ok, result} = Vor.Compiler.compile_string(source)

    # Compilation succeeded — all proven invariants passed
    assert result.module == Vor.Agent.CircuitBreaker
    assert result.graph != nil
  end

  test "safety violation produces compile error" do
    bad_source = """
    agent BadBreaker do
      state phase: :closed | :open

      protocol do
        accepts {:request, payload: term}
        emits {:ok, payload: term}
      end

      on {:request, payload: P} when phase == :closed do
        emit {:ok, payload: P}
      end

      on {:request, payload: P} when phase == :open do
        emit {:ok, payload: P}
      end

      safety "no forward when open" proven do
        never(phase == :open and emitted({:ok, _}))
      end
    end
    """

    result = Vor.Compiler.compile_string(bad_source)
    assert {:error, %{type: :invariant_violation}} = result
  end

  test "transition safety violation detected" do
    bad_source = """
    agent BadTransitions do
      state phase: :closed | :open | :half_open

      protocol do
        accepts {:request, payload: term}
        emits {:ok, payload: term}
      end

      on {:request, payload: P} when phase == :closed do
        transition phase: :half_open
        emit {:ok, payload: P}
      end

      safety "no direct closed to half_open" proven do
        never(transition from: :closed, to: :half_open)
      end
    end
    """

    result = Vor.Compiler.compile_string(bad_source)
    assert {:error, %{type: :invariant_violation}} = result
  end

  test "graph extraction produces correct structure" do
    source = File.read!("examples/circuit_breaker.vor")
    {:ok, graph} = Vor.Compiler.extract_graph(source)

    assert :closed in graph.states
    assert :open in graph.states
    assert :half_open in graph.states
    assert graph.initial_state == :closed

    # Verify no :ok emits from :open state
    open_emits = Map.get(graph.emit_map, :open, [])
    refute :ok in open_emits

    # Verify transitions
    assert Enum.any?(graph.transitions, fn t -> t.from == :closed and t.to == :open end)
    assert Enum.any?(graph.transitions, fn t -> t.from == :half_open and t.to == :closed end)
    refute Enum.any?(graph.transitions, fn t -> t.from == :closed and t.to == :half_open end)
  end

  test "monitored invariants are not verified at compile time" do
    source = """
    agent MonitoredOnly do
      state phase: :active | :idle

      protocol do
        accepts {:request, payload: term}
        emits {:ok, payload: term}
      end

      on {:request, payload: P} when phase == :active do
        emit {:ok, payload: P}
      end

      liveness "eventually idle" monitored do
        always(phase != :idle implies eventually(phase == :idle))
      end
    end
    """

    # Should compile fine — monitored invariants don't block compilation
    {:ok, _result} = Vor.Compiler.compile_string(source)
  end
end
