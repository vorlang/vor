defmodule Vor.MonitoredChannelTest do
  @moduledoc """
  F13 regression: the monitored tier now has a violation-reporting channel.

  Before the fix, `monitored(within:)` was fire-and-forget — a deadline exceeded
  and a resilience handler firing produced no signal, so a broken recovery
  degraded the system silently and the simulator stayed green. Now the compiler
  emits `[:vor, :monitored, :deadline_exceeded]` / `[:vor, :monitored,
  :resilience_fired]` (with `restores_target`), and the simulator reports a
  monitored violation when a deadline is exceeded and recovery does not restore a
  good state — while a healthy recovery is surfaced as `deadline_exceeded →
  recovered` and still passes.
  """
  use ExUnit.Case

  @moduletag :simulation

  # A worker that becomes busy on assign and never finishes on its own, so the
  # short deadline is always exceeded and the resilience handler always fires.
  # `RESILIENCE` is spliced in to make the recovery healthy or broken.
  defp source(resilience) do
    """
    agent Worker(deadline_ms: integer) do
      state phase: :idle | :busy
      state current_job: atom
      protocol do
        accepts {:assign, job_id: atom}
      end
      on {:assign, job_id: J} when phase == :idle do
        transition phase: :busy
        transition current_job: J
      end
      liveness "worker finishes eventually" monitored(within: deadline_ms) do
        always(phase != :idle implies eventually(phase == :idle))
      end
      resilience do
        on_invariant_violation("worker finishes eventually") ->
    #{resilience}
      end
    end

    system JobSystem do
      agent :w1, Worker(deadline_ms: 50)
      agent :w2, Worker(deadline_ms: 50)
      connect :w1 -> :w2
      connect :w2 -> :w1

      chaos do
        duration 2s
        seed 1
        check every: 400ms
        workload rate: 25
      end
    end
    """
  end

  defp run(resilience) do
    path =
      Path.join(
        System.tmp_dir!(),
        "vor_mon_#{System.unique_integer([:positive])}.vor"
      )

    File.write!(path, source(resilience))

    try do
      Vor.Simulator.run_file(path, %{
        duration_ms: 2000,
        seed: 1,
        workload_rate: 25,
        inject_faults: false,
        check_interval_ms: 400
      })
    after
      File.rm(path)
    end
  end

  test "broken recovery (does not restore target) is reported as a monitored violation" do
    result = run("      transition current_job: :nil")

    assert {:error, :violation, name, details, stats} = result
    assert details.kind == :monitored
    assert name =~ "worker finishes eventually"
    assert stats.monitored.violations != []
  end

  # F11: a fired resilience/timeout handler is now visible to coverage, and the
  # happy/fault distinction survives (unreached when the deadline never fires).
  test "coverage sees the resilience handler when it fires, not when it doesn't" do
    tag = :liveness_timeout_worker_finishes_eventually

    fired =
      Vor.Simulator.run_file(write_jobqueue(30), %{
        duration_ms: 2000,
        seed: 1,
        workload_rate: 25,
        inject_faults: false,
        check_interval_ms: 400
      })

    assert {:ok, _, stats} = fired
    assert tag in stats.coverage.agents.w1.handlers.reached

    happy =
      Vor.Simulator.run_file(write_jobqueue(10_000), %{
        duration_ms: 1500,
        seed: 1,
        workload_rate: 25,
        inject_faults: false,
        check_interval_ms: 400
      })

    assert {:ok, _, hstats} = happy
    refute tag in hstats.coverage.agents.w1.handlers.reached
  end

  # A minimal job queue whose workers requeue on timeout (healthy recovery), with
  # a tunable deadline so the timeout can be forced to fire or not.
  defp write_jobqueue(deadline) do
    src = """
    agent Worker(deadline_ms: integer) do
      state phase: :idle | :busy
      state current_job: atom
      protocol do
        accepts {:assign, job_id: atom}
        accepts {:finish}
      end
      on {:assign, job_id: J} when phase == :idle do
        transition phase: :busy
        transition current_job: J
      end
      on {:finish} when phase == :busy do
        transition phase: :idle
      end
      liveness "worker finishes eventually" monitored(within: deadline_ms) do
        always(phase != :idle implies eventually(phase == :idle))
      end
      resilience do
        on_invariant_violation("worker finishes eventually") ->
          transition phase: :idle
      end
    end
    system JobSystem do
      agent :w1, Worker(deadline_ms: #{deadline})
      agent :w2, Worker(deadline_ms: #{deadline})
      connect :w1 -> :w2
      connect :w2 -> :w1
    end
    """

    path = Path.join(System.tmp_dir!(), "vor_jq_#{System.unique_integer([:positive])}.vor")
    File.write!(path, src)
    path
  end

  test "healthy recovery is surfaced as recovered and still passes" do
    result = run("      transition phase: :idle")

    assert {:ok, outcome, stats} = result
    assert outcome in [:pass, :under_tested]
    # The deadline was exceeded (the worker never finishes on its own) and the
    # tier recovered — visible, not silent.
    inv = Enum.find(stats.monitored.invariants, &(&1.invariant == :"worker finishes eventually"))
    assert inv != nil
    assert inv.status == :recovered
    assert inv.deadlines_exceeded > 0
    assert stats.monitored.violations == []
  end
end
