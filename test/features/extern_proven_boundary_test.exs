defmodule Vor.Features.ExternProvenBoundaryTest do
  use ExUnit.Case

  # --- Negative: prohibited emit gated by extern result ---

  test "proven invariant with extern-dependent conditional emit is rejected" do
    source = """
    agent ExternProven do
      extern do
        Vor.TestHelpers.Echo.reflect(value: term) :: term
      end

      state phase: :idle | :active

      protocol do
        accepts {:check}
        emits {:allowed}
        emits {:denied}
      end

      safety "no allow when idle" proven do
        never(phase == :idle and emitted({:allowed}))
      end

      on {:check} when phase == :idle do
        result = Vor.TestHelpers.Echo.reflect(value: :test)
        if result == :true do
          emit {:allowed}
        else
          emit {:denied}
        end
      end

      on {:check} when phase == :active do
        emit {:allowed}
      end
    end
    """

    assert {:error, %{type: :extern_gated_invariant, name: "no allow when idle", message: msg}} =
             Vor.Compiler.compile_string(source)

    assert msg =~ "extern"
    assert msg =~ "monitored"
  end

  # --- Positive: extern in handler whose state isn't covered by the invariant ---

  test "proven invariant with extern not in verification path is accepted" do
    source = """
    agent ExternSafe do
      extern do
        Vor.TestHelpers.Echo.reflect(value: term) :: term
      end

      state phase: :idle | :active

      protocol do
        accepts {:process, value: term}
        emits {:done}
      end

      safety "no done when idle" proven do
        never(phase == :idle and emitted({:done}))
      end

      on {:process, value: V} when phase == :active do
        result = Vor.TestHelpers.Echo.reflect(value: V)
        emit {:done}
      end
    end
    """

    {:ok, _} = Vor.Compiler.compile_string(source)
  end

  # --- Positive: extern result used for transition (not gating an emit) ---

  test "proven invariant with extern used for transition not emit is accepted" do
    source = """
    agent ExternTransition do
      extern do
        Vor.TestHelpers.Echo.reflect(value: term) :: term
      end

      state phase: :idle | :active
      state data: term

      protocol do
        accepts {:load}
        emits {:loaded}
      end

      safety "no loaded when idle" proven do
        never(phase == :idle and emitted({:loaded}))
      end

      on {:load} when phase == :active do
        result = Vor.TestHelpers.Echo.reflect(value: :data)
        transition data: result
        emit {:loaded}
      end
    end
    """

    {:ok, _} = Vor.Compiler.compile_string(source)
  end

  # --- Positive: extern result used unconditionally before a non-prohibited emit ---

  test "proven invariant with unconditional emit after extern is accepted" do
    source = """
    agent ExternUnconditional do
      extern do
        Vor.TestHelpers.Echo.reflect(value: term) :: term
      end

      state phase: :free | :held

      protocol do
        accepts {:acquire, client: atom}
        emits {:queued, position: integer}
      end

      safety "no queued when free" proven do
        never(phase == :free and emitted({:queued, _}))
      end

      on {:acquire, client: C} when phase == :held do
        result = Vor.TestHelpers.Echo.reflect(value: C)
        emit {:queued, position: 1}
      end
    end
    """

    {:ok, _} = Vor.Compiler.compile_string(source)
  end

  # --- Positive: monitored tier escapes the check ---

  test "monitored invariant with extern-dependent path is accepted" do
    source = """
    agent ExternMonitored do
      extern do
        Vor.TestHelpers.Echo.reflect(value: term) :: term
      end

      state phase: :free | :held

      protocol do
        accepts {:check}
        emits {:grant, client: atom}
        emits {:denied}
      end

      liveness "eventually resolves" monitored(within: 5000) do
        always(phase == :held implies eventually(phase != :held))
      end

      on {:check} when phase == :held do
        result = Vor.TestHelpers.Echo.reflect(value: :test)
        if result == :true do
          emit {:grant, client: :someone}
        else
          emit {:denied}
        end
      end
    end
    """

    {:ok, _} = Vor.Compiler.compile_string(source)
  end

  # --- Negative: prohibited transition gated by extern result ---

  test "proven transition invariant with extern-gated branch is rejected" do
    source = """
    agent ExternTransitionGated do
      extern do
        Vor.TestHelpers.Echo.reflect(value: term) :: term
      end

      state phase: :open | :closed

      protocol do
        accepts {:probe}
        emits {:checked}
      end

      safety "open never closes via probe" proven do
        never(transition from: :open, to: :closed)
      end

      on {:probe} when phase == :open do
        result = Vor.TestHelpers.Echo.reflect(value: :test)
        if result == :true do
          transition phase: :closed
        end
        emit {:checked}
      end
    end
    """

    assert {:error, %{type: :extern_gated_invariant}} =
             Vor.Compiler.compile_string(source)
  end

  # --- Positive: nested conditionals where outer condition is not extern-tainted ---

  test "proven invariant accepted when condition uses params/state, not extern result" do
    source = """
    agent ParamGated do
      extern do
        Vor.TestHelpers.Echo.reflect(value: term) :: term
      end

      state phase: :idle | :active
      state count: integer

      protocol do
        accepts {:tick}
        emits {:high}
        emits {:low}
      end

      safety "no high when idle" proven do
        never(phase == :idle and emitted({:high}))
      end

      on {:tick} when phase == :active do
        result = Vor.TestHelpers.Echo.reflect(value: :ignored)
        if count > 5 do
          emit {:high}
        else
          emit {:low}
        end
      end
    end
    """

    {:ok, _} = Vor.Compiler.compile_string(source)
  end

  # --- All existing examples still compile ---

  test "all existing examples still compile" do
    for file <- Path.wildcard("examples/*.vor") do
      source = File.read!(file)

      result =
        if String.contains?(source, "system ") do
          Vor.Compiler.compile_system(source)
        else
          Vor.Compiler.compile_string(source)
        end

      assert match?({:ok, _}, result), "Failed to compile #{file}: #{inspect(result)}"
    end
  end

  # --- Runtime: an accepted agent actually starts and responds ---

  test "runtime: accepted agent (extern-not-in-verification-path) compiles, starts, and responds" do
    source = """
    agent ExternSafeRuntime do
      extern do
        Vor.TestHelpers.Echo.reflect(value: term) :: term
      end

      state phase: :active | :idle

      protocol do
        accepts {:process, value: term}
        emits {:done, value: term}
      end

      safety "no done when idle" proven do
        never(phase == :idle and emitted({:done, _}))
      end

      on {:process, value: V} when phase == :active do
        result = Vor.TestHelpers.Echo.reflect(value: V)
        emit {:done, value: result}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = :gen_statem.start_link(result.module, [], [])
    assert {:done, %{value: :hello}} = :gen_statem.call(pid, {:process, %{value: :hello}})
    :gen_statem.stop(pid)
  end
end
