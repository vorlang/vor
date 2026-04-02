defmodule Vor.Verification.SoundnessTest do
  use ExUnit.Case

  test "unsupported proven invariant fails compilation" do
    source = """
    agent BadProven do
      state phase: :a | :b

      protocol do
        accepts {:go}
        emits {:ok}
      end

      on {:go} when phase == :a do
        transition phase: :b
        emit {:ok}
      end

      safety "gibberish property" proven do
        some_unsupported_construct(x, y, z)
      end
    end
    """

    assert {:error, error} = Vor.Compiler.compile_string(source)
    assert error.type == :unsupported_invariant
    assert String.contains?(error.message, "Cannot verify")
  end

  test "supported proven invariant still passes" do
    source = """
    agent GoodProven do
      state phase: :a | :b

      protocol do
        accepts {:go}
        emits {:ok}
      end

      on {:go} when phase == :a do
        transition phase: :b
        emit {:ok}
      end

      safety "no emit in b" proven do
        never(phase == :b and emitted({:ok, _}))
      end
    end
    """

    {:ok, _mod} = Vor.Compiler.compile_string(source)
  end

  test "monitored invariant with complex body still compiles" do
    source = """
    agent MonitoredOk do
      state phase: :a | :b

      protocol do
        accepts {:go}
        emits {:ok}
      end

      on {:go} when phase == :a do
        transition phase: :b
        emit {:ok}
      end

      liveness "complex property" monitored(within: 5000) do
        always(phase == :a implies eventually(phase == :b))
      end

      resilience do
        on_invariant_violation("complex property") ->
          transition phase: :b
      end
    end
    """

    {:ok, _mod} = Vor.Compiler.compile_string(source)
  end
end
