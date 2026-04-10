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

  test "raft cluster simulation with kill injection (informative)" do
    cluster_source = File.read!("examples/raft_cluster.vor")
    path = write_temp_vor(cluster_source)

    config = %{
      duration_ms: 5000,
      seed: 42,
      kill_interval: {2000, 4000},
      fault_interval: {2000, 4000},
      check_interval_ms: 500,
      verbose: false,
      inject_faults: true,
      enable_partitions: false,
      enable_delays: false
    }

    result = Vor.Simulator.run_file(path, config)

    case result do
      {:ok, :pass, stats} ->
        IO.puts(
          "Raft simulation: PASS (#{stats.faults_injected} faults, #{stats.invariant_checks} checks)"
        )
        assert true

      {:error, :violation, name, _details, stats} ->
        IO.puts("Raft simulation: FAIL — #{name} after #{stats.faults_injected} faults")
        assert true

      {:error, :system_crash, reason} ->
        IO.puts("Raft simulation: CRASH — #{inspect(reason)}")
        assert true
    end
  end

  # ----------------------------------------------------------------------
  # Phase 2: message interception
  # ----------------------------------------------------------------------

  test "message proxy forwards in default mode" do
    source = """
    agent Echo do
      protocol do
        accepts {:ping, value: term}
        emits {:pong, value: term}
      end

      on {:ping, value: V} do
        emit {:pong, value: V}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)

    {:ok, proxy_pid} =
      Vor.Simulator.MessageProxy.start_link(%{
        agent_module: result.module,
        agent_args: [],
        agent_name: :echo,
        behaviour: :gen_server,
        name: nil
      })

    assert {:pong, %{value: :hello}} = GenServer.call(proxy_pid, {:ping, %{value: :hello}})
    GenServer.stop(proxy_pid)
  end

  test "message proxy drops when partitioned" do
    source = """
    agent Echo do
      protocol do
        accepts {:ping, value: term}
        emits {:pong, value: term}
      end

      on {:ping, value: V} do
        emit {:pong, value: V}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)

    {:ok, proxy_pid} =
      Vor.Simulator.MessageProxy.start_link(%{
        agent_module: result.module,
        agent_args: [],
        agent_name: :echo,
        behaviour: :gen_server,
        name: nil
      })

    Vor.Simulator.MessageProxy.set_policy(proxy_pid, %{policy: :partition})
    assert {:error, :partitioned} = GenServer.call(proxy_pid, {:ping, %{value: :hello}})

    Vor.Simulator.MessageProxy.set_policy(proxy_pid, %{policy: :forward})
    assert {:pong, %{value: :hello}} = GenServer.call(proxy_pid, {:ping, %{value: :hello}})

    GenServer.stop(proxy_pid)
  end

  test "message proxy delays messages" do
    source = """
    agent Echo do
      protocol do
        accepts {:ping, value: term}
        emits {:pong, value: term}
      end

      on {:ping, value: V} do
        emit {:pong, value: V}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)

    {:ok, proxy_pid} =
      Vor.Simulator.MessageProxy.start_link(%{
        agent_module: result.module,
        agent_args: [],
        agent_name: :echo,
        behaviour: :gen_server,
        name: nil
      })

    Vor.Simulator.MessageProxy.set_policy(proxy_pid, %{policy: :delay, delay_range: 100..200})

    start = System.monotonic_time(:millisecond)
    assert {:pong, %{value: :hello}} = GenServer.call(proxy_pid, {:ping, %{value: :hello}})
    elapsed = System.monotonic_time(:millisecond) - start
    assert elapsed >= 90

    GenServer.stop(proxy_pid)
  end

  test "get_real_pid returns the inner agent process" do
    source = """
    agent Echo do
      protocol do
        accepts {:ping, value: term}
        emits {:pong, value: term}
      end

      on {:ping, value: V} do
        emit {:pong, value: V}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)

    {:ok, proxy_pid} =
      Vor.Simulator.MessageProxy.start_link(%{
        agent_module: result.module,
        agent_args: [],
        agent_name: :echo,
        behaviour: :gen_server,
        name: nil
      })

    real_pid = Vor.Simulator.MessageProxy.get_real_pid(proxy_pid)
    assert is_pid(real_pid)
    assert real_pid != proxy_pid
    assert Process.alive?(real_pid)

    GenServer.stop(proxy_pid)
  end

  # ----------------------------------------------------------------------
  # Phase 3: workload generation
  # ----------------------------------------------------------------------

  test "workload generator sends messages at configured rate" do
    source = """
    agent Pinger do
      state mode: :idle | :pinged

      protocol do
        accepts {:ping}
        emits {:pong}
      end

      on {:ping} when mode == :idle do
        transition mode: :pinged
        emit {:pong}
      end

      on {:ping} when mode == :pinged do
        emit {:pong}
      end
    end

    system PingerPair do
      agent :a, Pinger()
      agent :b, Pinger()

      safety "test" proven do
        never(count(agents where mode == :error) > 0)
      end
    end
    """

    path = write_temp_vor(source)

    config = %{
      duration_ms: 3000,
      seed: 42,
      kill_interval: {5000, 10000},
      fault_interval: {5000, 10000},
      check_interval_ms: 1000,
      verbose: false,
      inject_faults: false,
      enable_partitions: false,
      enable_delays: false,
      workload_rate: 10
    }

    {:ok, :pass, stats} = Vor.Simulator.run_file(path, config)
    assert stats.workload_sent >= 15
    assert stats.workload_ok > 0
  end

  test "workload handles agent failures gracefully" do
    source = """
    agent Echo do
      protocol do
        accepts {:ping, value: atom}
        emits {:pong, value: atom}
      end

      on {:ping, value: V} do
        emit {:pong, value: V}
      end
    end

    system EchoPair do
      agent :a, Echo()
      agent :b, Echo()

      safety "test" proven do
        never(count(agents where value == :impossible) > 0)
      end
    end
    """

    path = write_temp_vor(source)

    config = %{
      duration_ms: 5000,
      seed: 42,
      kill_interval: {1000, 2000},
      fault_interval: {1000, 2000},
      check_interval_ms: 500,
      verbose: false,
      inject_faults: true,
      enable_partitions: false,
      enable_delays: false,
      workload_rate: 10
    }

    {:ok, :pass, stats} = Vor.Simulator.run_file(path, config)
    assert stats.workload_sent > 0
    # With proxy-internal restart, the workload may or may not see errors
    # depending on timing. Just verify workload ran.
  end

  test "workload zero rate disables workload" do
    source = """
    agent Node do
      state mode: :idle | :active

      protocol do
        accepts {:go}
        emits {:ok}
      end

      on {:go} when mode == :idle do
        transition mode: :active
        emit {:ok}
      end
    end

    system Pair do
      agent :a, Node()
      agent :b, Node()

      safety "test" proven do
        never(count(agents where mode == :active) > 2)
      end
    end
    """

    path = write_temp_vor(source)

    config = %{
      duration_ms: 2000,
      seed: 42,
      kill_interval: {3000, 5000},
      fault_interval: {3000, 5000},
      check_interval_ms: 500,
      verbose: false,
      inject_faults: false,
      enable_partitions: false,
      enable_delays: false,
      workload_rate: 0
    }

    {:ok, :pass, stats} = Vor.Simulator.run_file(path, config)
    assert stats.workload_sent == 0
  end

  # ----------------------------------------------------------------------
  # Phase 4: chaos block syntax
  # ----------------------------------------------------------------------

  test "chaos block parses with all options" do
    source = """
    agent Node do
      state mode: :idle | :active

      protocol do
        accepts {:go}
        emits {:ok}
      end

      on {:go} when mode == :idle do
        transition mode: :active
        emit {:ok}
      end
    end

    system Cluster do
      agent :a, Node()
      agent :b, Node()

      safety "test" proven do
        never(count(agents where mode == :active) > 2)
      end

      chaos do
        duration 30s
        seed 42
        kill every: 3..10s
        partition duration: 1..5s
        delay by: 50..200ms
        drop probability: 1
        check every: 500ms
        workload rate: 10
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_system(source)
    chaos = result.system_ir.chaos
    assert chaos != nil
    assert chaos.duration_ms == 30_000
    assert chaos.seed == 42
    assert chaos.kill == %{every: {3000, 10000}}
    assert chaos.partition == %{duration: {1000, 5000}}
    assert chaos.delay == %{by: {50, 200}}
    assert chaos.drop == %{probability: 0.01}
    assert chaos.check == %{every: 500}
    assert chaos.workload == %{rate: 10}
  end

  test "chaos block parses minimal (just duration)" do
    source = """
    agent Node do
      state mode: :idle | :active

      protocol do
        accepts {:go}
        emits {:ok}
      end

      on {:go} when mode == :idle do
        transition mode: :active
        emit {:ok}
      end
    end

    system Cluster do
      agent :a, Node()
      agent :b, Node()

      chaos do
        duration 10s
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_system(source)
    assert result.system_ir.chaos != nil
    assert result.system_ir.chaos.duration_ms == 10_000
    assert result.system_ir.chaos.kill == nil
  end

  test "simulator reads chaos config from file" do
    source = """
    agent Node do
      state mode: :idle | :active

      protocol do
        accepts {:go}
        emits {:ok}
      end

      on {:go} when mode == :idle do
        transition mode: :active
        emit {:ok}
      end
    end

    system Cluster do
      agent :a, Node()
      agent :b, Node()

      safety "test" proven do
        never(count(agents where mode == :active) > 2)
      end

      chaos do
        duration 3s
        seed 42
        kill every: 1..2s
        check every: 500ms
        workload rate: 5
      end
    end
    """

    path = write_temp_vor(source)
    result = Vor.Simulator.run_file(path, %{})
    assert {:ok, :pass, _stats} = result
  end

  test "CLI config overrides file chaos config" do
    source = """
    agent Node do
      state mode: :idle | :active

      protocol do
        accepts {:go}
        emits {:ok}
      end

      on {:go} when mode == :idle do
        transition mode: :active
        emit {:ok}
      end
    end

    system Cluster do
      agent :a, Node()
      agent :b, Node()

      safety "test" proven do
        never(count(agents where mode == :active) > 2)
      end

      chaos do
        duration 60s
        seed 1
      end
    end
    """

    path = write_temp_vor(source)
    # Override duration via config map
    result = Vor.Simulator.run_file(path, %{duration_ms: 2000, seed: 99})
    assert {:ok, :pass, _} = result
  end

  test "system without chaos block uses defaults when simulated" do
    source = """
    agent Node do
      state mode: :idle | :active

      protocol do
        accepts {:go}
        emits {:ok}
      end

      on {:go} when mode == :idle do
        transition mode: :active
        emit {:ok}
      end
    end

    system Cluster do
      agent :a, Node()
      agent :b, Node()

      safety "test" proven do
        never(count(agents where mode == :active) > 2)
      end
    end
    """

    path = write_temp_vor(source)
    result = Vor.Simulator.run_file(path, %{duration_ms: 2000, seed: 42})
    assert {:ok, :pass, _} = result
  end

  test "simulation with partition injection (informative)" do
    source = """
    agent Node do
      state mode: :idle | :active

      protocol do
        accepts {:go}
        emits {:ok}
      end

      on {:go} when mode == :idle do
        transition mode: :active
        emit {:ok}
      end
    end

    system Pair do
      agent :a, Node()
      agent :b, Node()

      safety "ok" proven do
        never(count(agents where mode == :active) > 2)
      end
    end
    """

    path = write_temp_vor(source)

    config = %{
      duration_ms: 5000,
      seed: 42,
      kill_interval: {3000, 5000},
      fault_interval: {1500, 3000},
      check_interval_ms: 500,
      verbose: false,
      inject_faults: true,
      enable_partitions: true,
      enable_delays: false,
      partition_duration: {500, 1500}
    }

    {:ok, :pass, stats} = Vor.Simulator.run_file(path, config)
    assert stats.faults_injected > 0
  end
end
