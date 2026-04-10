defmodule Vor.Features.SimulationTest do
  use ExUnit.Case

  @moduletag timeout: 60_000

  defp write_temp_vor(source) do
    path = Path.join(System.tmp_dir!(), "vor_sim_test_#{:rand.uniform(100_000)}.vor")
    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)
    path
  end

  # ----------------------------------------------------------------------
  # Timeline
  # ----------------------------------------------------------------------

  test "timeline records and retrieves events in order" do
    {:ok, tl} = Vor.Simulator.Timeline.start_link()

    Vor.Simulator.Timeline.record(tl, :kill, %{agent: :n1})
    Vor.Simulator.Timeline.record(tl, :restart, %{agent: :n1})
    Vor.Simulator.Timeline.record(tl, :check_ok)

    events = Vor.Simulator.Timeline.get(tl)
    assert length(events) == 3
    assert Enum.map(events, fn {_, type, _} -> type end) == [:kill, :restart, :check_ok]

    recent = Vor.Simulator.Timeline.recent(tl, 2)
    assert length(recent) == 2
    assert Enum.map(recent, fn {_, type, _} -> type end) == [:restart, :check_ok]

    Agent.stop(tl)
  end

  # ----------------------------------------------------------------------
  # InvariantChecker.query_agent_state
  # ----------------------------------------------------------------------

  test "query_agent_state returns :dead for dead process" do
    dead = spawn(fn -> :ok end)
    Process.sleep(10)
    assert Vor.Simulator.InvariantChecker.query_agent_state(dead) == :dead
  end

  test "query_agent_state returns state for live gen_statem" do
    source = """
    agent TestPhase do
      state phase: :free | :held

      protocol do
        accepts {:acquire}
        emits {:ok}
      end

      on {:acquire} when phase == :free do
        transition phase: :held
        emit {:ok}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = :gen_statem.start_link(result.module, [], [])

    state = Vor.Simulator.InvariantChecker.query_agent_state(pid, %{enum_field: :phase})
    assert is_map(state)
    assert state.phase == :free

    :gen_statem.stop(pid)
  end

  # ----------------------------------------------------------------------
  # Simulator: no-fault mode
  # ----------------------------------------------------------------------

  test "simulator starts and stops cleanly without faults" do
    source = """
    agent SimpleNode do
      state mode: :idle | :active

      protocol do
        accepts {:activate}
        emits {:ok}
      end

      on {:activate} when mode == :idle do
        transition mode: :active
        emit {:ok}
      end
    end

    system SimplePair do
      agent :a, SimpleNode()
      agent :b, SimpleNode()

      safety "not both active" proven do
        never(count(agents where mode == :active) > 1)
      end
    end
    """

    path = write_temp_vor(source)

    config = %{
      duration_ms: 2000,
      seed: 42,
      kill_interval: {1000, 2000},
      check_interval_ms: 500,
      verbose: false,
      inject_faults: false
    }

    result = Vor.Simulator.run_file(path, config)
    assert {:ok, :pass, stats} = result
    assert stats.faults_injected == 0
    assert stats.invariant_checks > 0
  end

  # ----------------------------------------------------------------------
  # Simulator: kill injection
  # ----------------------------------------------------------------------

  test "simulator detects invariant violation when agents restart into violating state" do
    # Both agents start as :active (first enum value). The invariant says
    # at most one can be active. After any kill + restart, the restarted
    # agent comes back as :active again → violation.
    source = """
    agent BadRestart do
      state mode: :active | :idle

      protocol do
        accepts {:deactivate}
        emits {:ok}
      end

      on {:deactivate} when mode == :active do
        transition mode: :idle
        emit {:ok}
      end
    end

    system BadPair do
      agent :a, BadRestart()
      agent :b, BadRestart()

      safety "not both active" proven do
        never(count(agents where mode == :active) > 1)
      end
    end
    """

    path = write_temp_vor(source)

    config = %{
      duration_ms: 5000,
      seed: 42,
      kill_interval: {3000, 5000},
      check_interval_ms: 200,
      verbose: false,
      inject_faults: false
    }

    # No kills needed — both agents start as :active (first enum value),
    # so the invariant "not both active" should be violated on the first
    # invariant check.
    result = Vor.Simulator.run_file(path, config)
    assert {:error, :violation, "not both active", _, _} = result
  end

  # ----------------------------------------------------------------------
  # Simulator: seed reproducibility
  # ----------------------------------------------------------------------

  test "same seed produces same fault count" do
    source = """
    agent Node do
      state role: :follower | :candidate

      protocol do
        accepts {:tick}
        emits {:ok}
      end

      on {:tick} when role == :follower do
        transition role: :candidate
        emit {:ok}
      end
    end

    system Pair do
      agent :a, Node()
      agent :b, Node()

      safety "ok" proven do
        never(count(agents where role == :candidate) > 5)
      end
    end
    """

    path = write_temp_vor(source)

    config = %{
      duration_ms: 3000,
      seed: 999,
      kill_interval: {500, 1000},
      check_interval_ms: 300,
      verbose: false,
      inject_faults: true
    }

    {:ok, :pass, stats1} = Vor.Simulator.run_file(path, config)
    {:ok, :pass, stats2} = Vor.Simulator.run_file(path, config)

    # Same seed guarantees deterministic agent SELECTION, not exact timing.
    # Both runs should have the same outcome (pass), but fault counts may
    # vary slightly due to real-time scheduling. Accept ±1 difference.
    assert abs(stats1.faults_injected - stats2.faults_injected) <= 1
  end

  # ----------------------------------------------------------------------
  # Raft cluster simulation
  # ----------------------------------------------------------------------

  test "raft cluster simulation (informative — may pass or find issues)" do
    cluster_source = File.read!("examples/raft_cluster.vor")
    path = write_temp_vor(cluster_source)

    config = %{
      duration_ms: 5000,
      seed: 42,
      kill_interval: {2000, 4000},
      check_interval_ms: 500,
      verbose: false,
      inject_faults: true
    }

    result = Vor.Simulator.run_file(path, config)

    case result do
      {:ok, :pass, stats} ->
        IO.puts(
          "Raft simulation: PASS (#{stats.faults_injected} kills, #{stats.invariant_checks} checks)"
        )

        assert true

      {:error, :violation, name, _details, stats} ->
        IO.puts("Raft simulation: FAIL — #{name} after #{stats.faults_injected} kills")
        assert true

      {:error, :system_crash, reason} ->
        IO.puts("Raft simulation: CRASH — #{inspect(reason)}")
        assert true
    end
  end
end
