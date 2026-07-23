defmodule Vor.Features.SimulationCoverageTest do
  @moduledoc """
  Phase 2b — coverage & relevance for simulation.

  These tests pin the "Seed 7" lesson: a green result must carry evidence that
  it engaged with something. A run whose harness degraded must not read as a
  clean pass (execution integrity, 2b.1), and a pass whose invariant subject was
  never observed must be reported as vacuous (relevance, 2b.3). Declared-vs-
  observed coverage (2b.2) is exercised against the live telemetry stream.
  """
  use ExUnit.Case

  @moduletag timeout: 90_000

  defp write_temp_vor(source) do
    path = Path.join(System.tmp_dir!(), "vor_sim_cov_test_#{:rand.uniform(1_000_000)}.vor")
    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)
    path
  end

  # A tiny two-agent system whose `:busy` phase is only reachable via a `:work`
  # message. With no workload and no faults, agents stay `:idle`, so the
  # invariant subject (`phase == :busy`) is never observed — a vacuous pass.
  defp idle_pool_source do
    """
    agent Worker do
      state phase: :idle | :busy

      protocol do
        accepts {:work}
        emits {:done}
      end

      on {:work} when phase == :idle do
        transition phase: :busy
        emit {:done}
      end
    end

    system Pool do
      agent :w1, Worker()
      agent :w2, Worker()

      safety "busy count bounded" checked do
        never(count(agents where phase == :busy) > 5)
      end
    end
    """
  end

  # ------------------------------------------------------------------
  # 2b.1 — Execution integrity / UNDER-TESTED
  # ------------------------------------------------------------------

  test "a run whose fault injector crashes reports UNDER-TESTED, not pass" do
    path = write_temp_vor(idle_pool_source())

    # Force the fault loop to crash after injecting one fault. Pre-2b, this would
    # have been reported as a clean `:pass` (no violation found) — the exact
    # "Seed 7" hole. The integrity check must now downgrade it.
    config = %{
      duration_ms: 2500,
      seed: 7,
      fault_interval: {200, 400},
      kill_interval: {200, 400},
      check_interval_ms: 300,
      inject_faults: true,
      __crash_fault_loop__: true
    }

    assert {:ok, :under_tested, stats} = Vor.Simulator.run_file(path, config)
    assert stats.integrity.degraded?
    assert Enum.any?(stats.integrity.harness_crashes, fn {name, _} -> name == :fault_injector end)

    assert Enum.any?(stats.integrity.reasons, fn r ->
             String.contains?(r, "crashed")
           end)
  end

  test "a run that injects no faults reports UNDER-TESTED (the Seed 7 shape)" do
    path = write_temp_vor(idle_pool_source())

    # Faults requested, but the interval is longer than the run: nothing fires.
    # A pass here is under-tested, not clean.
    config = %{
      duration_ms: 1500,
      seed: 1,
      fault_interval: {30_000, 60_000},
      kill_interval: {30_000, 60_000},
      check_interval_ms: 300,
      inject_faults: true
    }

    assert {:ok, :under_tested, stats} = Vor.Simulator.run_file(path, config)
    assert stats.integrity.faults_injected == 0

    assert Enum.any?(stats.integrity.reasons, fn r ->
             String.contains?(r, "no faults were injected")
           end)
  end

  test "a healthy fault-injecting run reports a clean pass" do
    path = write_temp_vor(idle_pool_source())

    config = %{
      duration_ms: 2500,
      seed: 3,
      fault_interval: {200, 400},
      kill_interval: {200, 400},
      check_interval_ms: 300,
      inject_faults: true
    }

    assert {:ok, :pass, stats} = Vor.Simulator.run_file(path, config)
    refute stats.integrity.degraded?
    assert stats.integrity.faults_injected > 0
    assert stats.integrity.invariant_checks > 0
  end

  # ------------------------------------------------------------------
  # 2b.3 — Invariant relevance / vacuity
  # ------------------------------------------------------------------

  test "an invariant whose subject never appears is reported VACUOUS" do
    path = write_temp_vor(idle_pool_source())

    # No workload, no faults: agents never leave :idle, so `phase == :busy` is
    # never observed. The pass is real but vacuous — same word, same meaning as
    # the model checker's vacuity.
    config = %{
      duration_ms: 1500,
      seed: 5,
      check_interval_ms: 300,
      inject_faults: false
    }

    assert {:ok, :pass, stats} = Vor.Simulator.run_file(path, config)

    inv = Enum.find(stats.relevance, &(&1.name == "busy count bounded"))
    assert inv, "expected relevance entry for the invariant"
    assert inv.relevance == :vacuous
    assert inv.subject_live_checks == 0
    assert inv.total_checks > 0
  end

  test "an invariant whose subject is live is reported SUBSTANTIVE" do
    path = write_temp_vor(idle_pool_source())

    # Drive :work messages so agents reach :busy — the subject is now live.
    config = %{
      duration_ms: 2500,
      seed: 5,
      check_interval_ms: 300,
      inject_faults: false,
      workload_rate: 40
    }

    assert {:ok, outcome, stats} = Vor.Simulator.run_file(path, config)
    assert outcome in [:pass, :under_tested]

    inv = Enum.find(stats.relevance, &(&1.name == "busy count bounded"))
    assert inv, "expected relevance entry for the invariant"
    assert inv.relevance == :substantive
    assert inv.subject_live_checks > 0
  end

  # ------------------------------------------------------------------
  # 2b.2 — Declared-vs-observed coverage
  # ------------------------------------------------------------------

  test "coverage reports reached vs declared states and messages" do
    path = write_temp_vor(idle_pool_source())

    config = %{
      duration_ms: 2500,
      seed: 9,
      check_interval_ms: 300,
      inject_faults: false,
      workload_rate: 40
    }

    assert {:ok, _outcome, stats} = Vor.Simulator.run_file(path, config)
    cov = stats.coverage
    assert is_map(cov)

    w1 = cov.agents[:w1]
    assert w1, "expected coverage for instance :w1"

    # `phase` declares [:idle, :busy]; the workload should reach :busy.
    assert :idle in w1.states.phase.declared
    assert :busy in w1.states.phase.declared
    assert :busy in w1.states.phase.reached

    # The `:work` handler fires (received) and `:done` is emitted.
    assert :work in w1.handlers.reached
    assert :done in w1.emits.reached

    # Totals are {reached, declared} pairs.
    {rs, ds} = cov.totals.states
    assert ds > 0
    assert rs <= ds
  end

  # ------------------------------------------------------------------
  # 2b.4 — Sweep-level aggregation
  # ------------------------------------------------------------------

  test "a sweep aggregates outcomes, union coverage, and union relevance" do
    path = write_temp_vor(idle_pool_source())
    {:ok, system_info} = Vor.Simulator.compile_for_simulation(File.read!(path))

    base = %{
      duration_ms: 1800,
      check_interval_ms: 300,
      inject_faults: false,
      workload_rate: 40
    }

    sweep = Vor.Simulator.Sweep.run(system_info, [21, 22], base)
    agg = sweep.aggregate

    assert agg.run_count == 2
    # Every run should be non-failing on this trivially-safe system.
    assert agg.outcomes.fail == 0
    assert agg.outcomes.error == 0
    assert agg.outcomes.pass + agg.outcomes.under_tested == 2

    # Union coverage reaches :busy across the sweep (workload drives it).
    assert :busy in agg.coverage.agents[:w1].states.phase.reached

    # Union relevance: the subject was live in at least one seed → substantive.
    inv = Enum.find(agg.relevance, &(&1.name == "busy count bounded"))
    assert inv
    assert inv.relevance == :substantive
    assert inv.substantive_seeds >= 1
    assert inv.total_seeds == 2
  end
end
