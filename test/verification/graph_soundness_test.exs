defmodule Vor.Verification.GraphSoundnessTest do
  use ExUnit.Case

  test "non-state atom guard does not corrupt state graph" do
    source = """
    agent MixedGuards do
      state phase: :idle | :active | :done
      state mode: atom

      protocol do
        accepts {:start, mode: atom}
        accepts {:finish}
        emits {:ok}
      end

      on {:start, mode: M} when phase == :idle do
        transition phase: :active
        transition mode: M
        emit {:ok}
      end

      on {:finish} when phase == :active do
        transition phase: :done
        emit {:ok}
      end
    end
    """

    {:ok, graph} = Vor.Compiler.extract_graph(source)

    # Graph should only contain declared states
    assert :idle in graph.states
    assert :active in graph.states
    assert :done in graph.states

    # Transitions should only be between declared states
    Enum.each(graph.transitions, fn t ->
      assert t.from in graph.states
      assert t.to in graph.states
    end)
  end

  test "compound guard with state and non-state fields extracts correctly" do
    source = """
    agent CompoundGuard do
      state phase: :idle | :running | :done
      state priority: integer

      protocol do
        accepts {:start}
        accepts {:finish}
        emits {:ok}
        emits {:rejected}
      end

      on {:start} when phase == :idle and priority > 0 do
        transition phase: :running
        emit {:ok}
      end

      on {:start} when phase == :idle and priority <= 0 do
        emit {:rejected}
      end

      on {:finish} when phase == :running do
        transition phase: :done
        emit {:ok}
      end
    end
    """

    {:ok, graph} = Vor.Compiler.extract_graph(source)

    # Only declared phase states
    assert Enum.sort(graph.states) == [:done, :idle, :running]

    # Transitions from idle and running exist
    assert Enum.any?(graph.transitions, fn t -> t.from == :idle and t.to == :running end)
    assert Enum.any?(graph.transitions, fn t -> t.from == :running and t.to == :done end)
  end

  test "safety verification correct with mixed guard fields" do
    source = """
    agent SafeWithMixed do
      state phase: :open | :closed
      state level: integer

      protocol do
        accepts {:request}
        emits {:ok}
        emits {:rejected}
      end

      on {:request} when phase == :closed do
        emit {:ok}
      end

      on {:request} when phase == :open do
        emit {:rejected}
      end

      safety "no ok when open" proven do
        never(phase == :open and emitted({:ok, _}))
      end
    end
    """

    {:ok, _mod} = Vor.Compiler.compile_string(source)
  end

  test "safety violation detected with mixed guard fields" do
    source = """
    agent UnsafeWithMixed do
      state phase: :open | :closed
      state level: integer

      protocol do
        accepts {:request}
        emits {:ok}
      end

      on {:request} when phase == :open do
        emit {:ok}
      end

      on {:request} when phase == :closed do
        emit {:ok}
      end

      safety "no ok when open" proven do
        never(phase == :open and emitted({:ok, _}))
      end
    end
    """

    assert {:error, _} = Vor.Compiler.compile_string(source)
  end
end
