defmodule Vor.LivenessVerdictTest do
  @moduledoc """
  F10 regression: the system-tier (multi-agent) `liveness ... proven` verdict.

  Before the fix, `run_liveness_check` computed a violation into
  `stats.liveness.results` but `check_file` ignored it and returned `:proven`
  anyway — a green-but-empty at the check tier. And an agent-qualified condition
  (`w1.phase == :busy`) that the evaluator can't handle silently evaluated to
  `false`, converting unsupported syntax into a vacuous proof.

  The fix fails closed: a detected liveness violation fails the check, and an
  unevaluable liveness condition refuses loudly. These tests are the
  red-before-green record for both.
  """
  use ExUnit.Case, async: true

  @opts [max_depth: 20, max_queue: 3, integer_bound: 2, max_states: 300_000, allow_vacuous: true]

  # A worker whose `busy` state is a terminal sink: assigned, but with no path
  # back to idle. `always(phase == :busy implies eventually(phase == :idle))`
  # must be VIOLATED, not proven. (Red before the fix: returned `:proven`.)
  test "stuck worker (terminal deadlock sink) is reported violated, not proven" do
    source = """
    agent Worker() do
      state phase: :idle | :busy
      protocol do
        accepts {:assign, job_id: atom}
      end
      on {:assign, job_id: J} when phase == :idle do
        transition phase: :busy
      end
    end

    agent Driver() do
      state s: :on | :off
      protocol do
        accepts {:go}
        sends {:assign, job_id: atom}
      end
      on {:go} when s == :on do
        send :w {:assign, job_id: :j1}
      end
    end

    system Sys do
      agent :w, Worker()
      agent :d, Driver()
      connect :d -> :w
      liveness "drains" proven do
        always(phase == :busy implies eventually(phase == :idle))
      end
    end
    """

    assert {:error, :liveness_violation, "drains", _trace, _stats} =
             Vor.Explorer.check_file(source, @opts)
  end

  # A two-agent ping-pong that loops forever between :a and :b without ever
  # reaching :c: a genuine non-progress cycle. Must be VIOLATED. (Red: `:proven`.)
  test "livelock cycle (never reaches target) is reported violated, not proven" do
    source = """
    agent PingA() do
      state phase: :a | :b | :c
      protocol do
        accepts {:ping}
        sends {:ping}
      end
      on {:ping} when phase == :a do
        transition phase: :b
        send :pb {:ping}
      end
      on {:ping} when phase == :b do
        transition phase: :a
        send :pb {:ping}
      end
    end

    agent PingB() do
      state phase: :a | :b | :c
      protocol do
        accepts {:ping}
        sends {:ping}
      end
      on {:ping} when phase == :a do
        transition phase: :b
        send :pa {:ping}
      end
      on {:ping} when phase == :b do
        transition phase: :a
        send :pa {:ping}
      end
    end

    system Spin do
      agent :pa, PingA()
      agent :pb, PingB()
      connect :pa -> :pb
      connect :pb -> :pa
      liveness "reaches c" proven do
        always(phase == :b implies eventually(phase == :c))
      end
    end
    """

    assert {:error, :liveness_violation, "reaches c", _trace, _stats} =
             Vor.Explorer.check_file(source, @opts)
  end

  # The substantive path must still verify: a genuinely-held liveness stays proven.
  test "a genuinely-held liveness still verifies (no over-fail-closing)" do
    source = """
    agent Toggle do
      state mode: :off | :on
      protocol do
        accepts {:turn_on}
        accepts {:turn_off}
        emits {:ok}
      end
      on {:turn_on} when mode == :off do
        transition mode: :on
        emit {:ok}
      end
      on {:turn_off} when mode == :on do
        transition mode: :off
        emit {:ok}
      end
    end

    system TogglePair do
      agent :a, Toggle()
      agent :b, Toggle()
      liveness "eventually on" proven do
        always(mode == :off implies eventually(mode == :on))
      end
    end
    """

    assert {:ok, status, _stats} = Vor.Explorer.check_file(source, max_depth: 10, max_states: 1000)
    assert status in [:proven, :bounded]
  end

  # An agent-qualified condition the evaluator cannot handle must REFUSE, not
  # silently evaluate to false and "prove" vacuously. (Red: returned `:proven`.)
  test "agent-qualified liveness condition is refused, not vacuously proven" do
    source = """
    agent Worker() do
      state phase: :idle | :busy
      protocol do
        accepts {:assign, job_id: atom}
      end
      on {:assign, job_id: J} when phase == :idle do
        transition phase: :busy
      end
    end

    agent Driver() do
      state s: :on | :off
      protocol do
        accepts {:go}
        sends {:assign, job_id: atom}
      end
      on {:go} when s == :on do
        send :w {:assign, job_id: :j1}
      end
    end

    system Sys do
      agent :w, Worker()
      agent :d, Driver()
      connect :d -> :w
      liveness "drains" proven do
        always(w.phase == :busy implies eventually(w.phase == :idle))
      end
    end
    """

    assert {:error, :unsupported_liveness, "drains", reason, _stats} =
             Vor.Explorer.check_file(source, @opts)

    assert reason =~ "monitored" or reason =~ "simple state condition"
  end
end
