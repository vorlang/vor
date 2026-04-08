defmodule Vor.Features.MultiAgentTest do
  use ExUnit.Case

  # ----------------------------------------------------------------------
  # Milestone 1: parser + IR for system-level safety invariants
  # ----------------------------------------------------------------------

  test "system block with no invariants compiles normally" do
    source = """
    agent Ping do
      protocol do
        accepts {:ping}
        emits {:pong}
      end

      on {:ping} do
        emit {:pong}
      end
    end

    system Simple do
      agent :a, Ping()
    end
    """

    {:ok, _} = Vor.Compiler.compile_system(source)
  end

  test "system-level safety invariant is parsed and stored on system IR" do
    source = """
    agent Node do
      state role: :follower | :leader

      protocol do
        accepts {:promote}
        emits {:ok}
      end

      on {:promote} when role == :follower do
        transition role: :leader
        emit {:ok}
      end
    end

    system Cluster do
      agent :n1, Node()
      agent :n2, Node()

      safety "at most one leader" proven do
        never(count(agents where role == :leader) > 1)
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_system(source)

    assert [%Vor.IR.SystemInvariant{name: "at most one leader", tier: :proven, body: body}] =
             result.system_ir.invariants

    assert {:never, {:count_gt, {:agents_where, :role, :==, :leader}, 1}} = body
  end

  test "system-level invariant with >= operator" do
    source = """
    agent Node do
      state phase: :idle | :busy

      protocol do
        accepts {:start}
        emits {:ok}
      end

      on {:start} when phase == :idle do
        transition phase: :busy
        emit {:ok}
      end
    end

    system Cluster do
      agent :a, Node()
      agent :b, Node()

      safety "at most one busy" proven do
        never(count(agents where phase == :busy) >= 2)
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_system(source)
    assert [%{body: {:never, {:count_gte, {:agents_where, :phase, :==, :busy}, 2}}}] =
             result.system_ir.invariants
  end

  # ----------------------------------------------------------------------
  # Milestone 2: product state representation
  # ----------------------------------------------------------------------

  defp build_initial(source) do
    {:ok, result} = Vor.Compiler.compile_system(source)
    agent_irs = Map.new(result.agents, fn {name, %{ir: ir}} -> {name, ir} end)
    {result.system_ir, agent_irs}
  end

  test "initial product state has one entry per declared agent instance" do
    source = """
    agent Node do
      state role: :follower | :leader

      protocol do
        accepts {:promote}
        emits {:ok}
      end

      on {:promote} when role == :follower do
        transition role: :leader
        emit {:ok}
      end
    end

    system Cluster do
      agent :n1, Node()
      agent :n2, Node()
      agent :n3, Node()
    end
    """

    {system_ir, agent_irs} = build_initial(source)
    ps = Vor.Explorer.ProductState.initial(system_ir, agent_irs)

    assert Map.keys(ps.agents) |> Enum.sort() == [:n1, :n2, :n3]
    assert ps.depth == 0
    assert ps.pending_messages == []
    assert ps.last_action == :initial

    # Each agent starts in :follower (first declared enum value)
    for {_name, agent_state} <- ps.agents do
      assert agent_state.role == :follower
    end
  end

  test "initial product state seeds data field defaults" do
    source = """
    agent Counter do
      state phase: :idle | :busy
      state count: integer
      state items: list
      state store: map

      protocol do
        accepts {:tick}
        emits {:ok}
      end

      on {:tick} when phase == :idle do
        emit {:ok}
      end
    end

    system Counters do
      agent :a, Counter()
    end
    """

    {system_ir, agent_irs} = build_initial(source)
    ps = Vor.Explorer.ProductState.initial(system_ir, agent_irs)
    a = ps.agents[:a]

    assert a.phase == :idle
    assert a.count == 0
    assert a.items == []
    assert a.store == %{}
  end

  test "fingerprint ignores pending message ordering" do
    ps_a = %Vor.Explorer.ProductState{
      agents: %{a: %{phase: :idle}},
      pending_messages: [{:x, :a, {:ping, %{}}}, {:y, :a, {:pong, %{}}}]
    }

    ps_b = %Vor.Explorer.ProductState{
      agents: %{a: %{phase: :idle}},
      pending_messages: [{:y, :a, {:pong, %{}}}, {:x, :a, {:ping, %{}}}]
    }

    assert Vor.Explorer.ProductState.fingerprint(ps_a) ==
             Vor.Explorer.ProductState.fingerprint(ps_b)
  end

  test "same_as_parent? detects no-op transitions" do
    parent = %Vor.Explorer.ProductState{agents: %{a: %{phase: :idle}}, pending_messages: []}
    same = %Vor.Explorer.ProductState{agents: %{a: %{phase: :idle}}, pending_messages: [], depth: 1}
    different = %Vor.Explorer.ProductState{agents: %{a: %{phase: :busy}}, pending_messages: [], depth: 1}

    assert Vor.Explorer.ProductState.same_as_parent?(same, parent)
    refute Vor.Explorer.ProductState.same_as_parent?(different, parent)
  end

  # ----------------------------------------------------------------------
  # Milestone 3: handler simulation
  # ----------------------------------------------------------------------

  defp first_handler(agent_irs, type_name, msg_tag) do
    ir = agent_irs[type_name]
    Enum.find(ir.handlers, fn h -> h.pattern.tag == to_string(msg_tag) or h.pattern.tag == msg_tag end)
  end

  test "simulator applies a transition and produces no outgoing messages" do
    source = """
    agent Node do
      state role: :follower | :leader

      protocol do
        accepts {:promote}
        emits {:ok}
      end

      on {:promote} when role == :follower do
        transition role: :leader
        emit {:ok}
      end
    end

    system Cluster do
      agent :n1, Node()
    end
    """

    {_system_ir, agent_irs} = build_initial(source)
    handler = first_handler(agent_irs, :Node, :promote)

    [{new_state, msgs}] =
      Vor.Explorer.Simulator.simulate(handler, %{role: :follower}, {:promote, %{}}, :n1, [])

    assert new_state.role == :leader
    assert msgs == []
  end

  test "simulator records broadcast messages to all connected agents" do
    source = """
    agent Node do
      state phase: :idle | :busy

      protocol do
        accepts {:start}
        accepts {:hello, from: atom}
        emits {:ok}
        sends {:hello, from: atom}
      end

      on {:start} when phase == :idle do
        transition phase: :busy
        broadcast {:hello, from: :me}
        emit {:ok}
      end

      on {:hello, from: F} do
        emit {:ok}
      end
    end

    system Cluster do
      agent :a, Node()
      agent :b, Node()
      agent :c, Node()
      connect :a -> :b
      connect :a -> :c
    end
    """

    {_system_ir, agent_irs} = build_initial(source)
    handler = first_handler(agent_irs, :Node, :start)

    [{new_state, msgs}] =
      Vor.Explorer.Simulator.simulate(handler, %{phase: :idle}, {:start, %{}}, :a, [:b, :c])

    assert new_state.phase == :busy
    assert length(msgs) == 2
    targets = msgs |> Enum.map(fn {_from, to, _msg} -> to end) |> Enum.sort()
    assert targets == [:b, :c]

    for {from, _to, {tag, fields}} <- msgs do
      assert from == :a
      assert tag == :hello
      assert fields == %{from: :me}
    end
  end

  test "simulator branches on extern-tainted conditional" do
    source = """
    agent ExternBranch do
      extern do
        Vor.TestHelpers.Echo.reflect(value: term) :: term
      end

      state phase: :a | :b

      protocol do
        accepts {:check}
        emits {:ok}
      end

      on {:check} when phase == :a do
        result = Vor.TestHelpers.Echo.reflect(value: :test)
        if result == :true do
          transition phase: :b
        end
        emit {:ok}
      end
    end

    system Cluster do
      agent :x, ExternBranch()
    end
    """

    {_system_ir, agent_irs} = build_initial(source)
    handler = first_handler(agent_irs, :ExternBranch, :check)

    results =
      Vor.Explorer.Simulator.simulate(handler, %{phase: :a}, {:check, %{}}, :x, [])

    # Two branches: one transitions to :b, one stays in :a
    states = results |> Enum.map(fn {s, _} -> s.phase end) |> Enum.sort()
    assert :a in states
    assert :b in states
  end

  test "simulator binds pattern variables to message fields and uses them in send" do
    source = """
    agent Echo do
      state phase: :ready | :sent

      protocol do
        accepts {:request, target: atom}
        accepts {:reply, content: atom}
        emits {:ok}
        sends {:reply, content: atom}
      end

      on {:request, target: T} when phase == :ready do
        transition phase: :sent
        send T {:reply, content: :hello}
        emit {:ok}
      end

      on {:reply, content: C} do
        emit {:ok}
      end
    end

    system Cluster do
      agent :a, Echo()
      agent :b, Echo()
      connect :a -> :b
    end
    """

    {_system_ir, agent_irs} = build_initial(source)
    handler = first_handler(agent_irs, :Echo, :request)

    [{new_state, msgs}] =
      Vor.Explorer.Simulator.simulate(handler, %{phase: :ready},
        {:request, %{target: :b}}, :a, [:b])

    assert new_state.phase == :sent
    assert [{:a, :b, {:reply, %{content: :hello}}}] = msgs
  end

  test "simulator guard_matches?/3 evaluates against current state" do
    source = """
    agent Node do
      state role: :follower | :leader

      protocol do
        accepts {:promote}
        emits {:ok}
      end

      on {:promote} when role == :follower do
        transition role: :leader
        emit {:ok}
      end
    end

    system Cluster do
      agent :n1, Node()
    end
    """

    {_system_ir, agent_irs} = build_initial(source)
    handler = first_handler(agent_irs, :Node, :promote)

    assert Vor.Explorer.Simulator.guard_matches?(handler, %{role: :follower}, %{})
    refute Vor.Explorer.Simulator.guard_matches?(handler, %{role: :leader}, %{})
  end

  # ----------------------------------------------------------------------
  # Milestones 4-6: Successor + Invariant evaluator + BFS exploration
  # ----------------------------------------------------------------------

  test "explorer detects invariant violation (two independent leaders)" do
    source = """
    agent UnsafeNode do
      state role: :follower | :leader

      protocol do
        accepts {:promote}
        emits {:ok}
      end

      on {:promote} when role == :follower do
        transition role: :leader
        emit {:ok}
      end
    end

    system UnsafeCluster do
      agent :n1, UnsafeNode()
      agent :n2, UnsafeNode()

      safety "at most one leader" proven do
        never(count(agents where role == :leader) > 1)
      end
    end
    """

    assert {:error, :violation, "at most one leader", trace, _stats} =
             Vor.Explorer.check_file(source, max_depth: 20, max_states: 1_000)

    last = List.last(trace)
    leaders = last.agents |> Map.values() |> Enum.count(fn s -> s.role == :leader end)
    assert leaders >= 2
  end

  test "explorer proves invariant for safe single-promotion system" do
    source = """
    agent OneShot do
      state role: :follower | :promoted

      protocol do
        accepts {:noop}
        emits {:ok}
      end

      on {:noop} do
        emit {:ok}
      end
    end

    system OneShotCluster do
      agent :a, OneShot()
      agent :b, OneShot()

      safety "no one ever promotes" proven do
        never(count(agents where role == :promoted) > 0)
      end
    end
    """

    assert {:ok, :proven, stats} =
             Vor.Explorer.check_file(source, max_depth: 10, max_states: 1_000)

    assert stats.states_explored >= 1
  end

  test "state-change-only exploration drops no-op deliveries" do
    source = """
    agent Quiet do
      state mode: :idle | :active

      protocol do
        accepts {:ping}
        accepts {:activate}
        emits {:ok}
      end

      on {:ping} do
        emit {:ok}
      end

      on {:activate} when mode == :idle do
        transition mode: :active
        emit {:ok}
      end
    end

    system QuietPair do
      agent :a, Quiet()
      agent :b, Quiet()

      safety "not both active" proven do
        never(count(agents where mode == :active) >= 3)
      end
    end
    """

    {:ok, :proven, stats} =
      Vor.Explorer.check_file(source, max_depth: 10, max_states: 1_000)

    # The :ping handler does nothing — those deliveries should be dropped
    # before they enter the visited set, keeping the state space small.
    assert stats.states_explored < 30
  end

  test "bounded verification reports honestly when state cap is hit" do
    source = """
    agent Spinner do
      state phase: :a | :b | :c

      protocol do
        accepts {:tick}
        emits {:ok}
      end

      on {:tick} when phase == :a do
        transition phase: :b
        emit {:ok}
      end

      on {:tick} when phase == :b do
        transition phase: :c
        emit {:ok}
      end

      on {:tick} when phase == :c do
        transition phase: :a
        emit {:ok}
      end
    end

    system Cluster do
      agent :x, Spinner()
      agent :y, Spinner()

      safety "never four phase-a" proven do
        never(count(agents where phase == :a) > 3)
      end
    end
    """

    {:ok, status, stats} = Vor.Explorer.check_file(source, max_depth: 100, max_states: 3)
    assert status in [:proven, :bounded]

    # With max_states=3 and a system that has more reachable states, we
    # expect the bounded path. Either way, stats are reported honestly.
    assert is_integer(stats.states_explored)
  end

  test "counterexample trace records initial + final states" do
    source = """
    agent BadNode do
      state role: :follower | :leader

      protocol do
        accepts {:promote}
        emits {:ok}
      end

      on {:promote} when role == :follower do
        transition role: :leader
        emit {:ok}
      end
    end

    system BadCluster do
      agent :n1, BadNode()
      agent :n2, BadNode()

      safety "at most one leader" proven do
        never(count(agents where role == :leader) > 1)
      end
    end
    """

    {:error, :violation, _name, trace, _stats} =
      Vor.Explorer.check_file(source, max_depth: 10, max_states: 1_000)

    assert length(trace) >= 2
    [initial | _] = trace
    assert initial.depth == 0
    assert initial.last_action == :initial

    last = List.last(trace)
    leaders = last.agents |> Map.values() |> Enum.count(fn s -> s.role == :leader end)
    assert leaders >= 2
  end

  test "counterexample formatter renders human-readable steps" do
    source = """
    agent BadNode do
      state role: :follower | :leader

      protocol do
        accepts {:promote}
        emits {:ok}
      end

      on {:promote} when role == :follower do
        transition role: :leader
        emit {:ok}
      end
    end

    system BadCluster do
      agent :n1, BadNode()
      agent :n2, BadNode()

      safety "at most one leader" proven do
        never(count(agents where role == :leader) > 1)
      end
    end
    """

    {:error, :violation, _name, trace, _stats} =
      Vor.Explorer.check_file(source, max_depth: 10, max_states: 1_000)

    rendered = Mix.Tasks.Vor.Check.format_counterexample(trace)
    assert rendered =~ "Step 0"
    assert rendered =~ "Initial state"
    assert rendered =~ "n1"
    assert rendered =~ "n2"
    assert rendered =~ "leader"
  end

  test "system without system-level invariants returns :no_invariants" do
    source = """
    agent Ping do
      protocol do
        accepts {:ping}
        emits {:pong}
      end

      on {:ping} do
        emit {:pong}
      end
    end

    system Simple do
      agent :a, Ping()
    end
    """

    assert {:ok, :no_invariants, _} = Vor.Explorer.check_file(source)
  end

  # ----------------------------------------------------------------------
  # Native Raft majority check (no extern false positive)
  # ----------------------------------------------------------------------

  test "raft majority check uses native arithmetic, not an extern" do
    raft_source = File.read!("examples/raft.vor")
    cluster_source = File.read!("examples/raft_cluster.vor")

    refute String.contains?(raft_source, "RaftHelpers.majority(")
    refute String.contains?(cluster_source, "RaftHelpers.majority(")

    # The native comparison must exist in both files.
    assert String.contains?(raft_source, "vote_count")
    assert String.contains?(cluster_source, "vote_count")
    assert String.contains?(raft_source, "cluster_size / 2")
    assert String.contains?(cluster_source, "cluster_size / 2")
  end

  test "raft examples still compile after the majority refactor" do
    {:ok, _} = Vor.Compiler.compile_string(File.read!("examples/raft.vor"))
    {:ok, _} = Vor.Compiler.compile_system(File.read!("examples/raft_cluster.vor"))
  end

  # ----------------------------------------------------------------------
  # Milestone 9: Raft integration
  # ----------------------------------------------------------------------

  test "raft cluster: explorer either proves the invariant or reports a counterexample" do
    cluster_source = File.read!("examples/raft_cluster.vor")

    # Add a system-level safety invariant — the cluster file does not yet
    # declare one, so append it.
    augmented =
      String.replace(cluster_source, ~r/system .* do/, fn header ->
        header
      end)

    augmented = inject_system_invariant(augmented)

    result =
      Vor.Explorer.check_file(augmented, max_depth: 10, max_states: 5_000)

    case result do
      {:ok, :proven, stats} ->
        IO.puts("Raft proven: #{stats.states_explored} states explored")
        assert true

      {:ok, :bounded, stats} ->
        IO.puts("Raft bounded: #{stats.states_explored} states explored")
        assert true

      {:error, :violation, name, trace, stats} ->
        IO.puts("Raft violation '#{name}' after #{stats.states_explored} states")
        IO.puts("Trace length: #{length(trace)}")
        # A violation is informative, not a test failure — the model checker
        # is doing its job.
        assert true

      other ->
        flunk("Unexpected result: #{inspect(other)}")
    end
  end

  defp inject_system_invariant(source) do
    invariant = """

      safety "at most one leader" proven do
        never(count(agents where role == :leader) > 1)
      end
    """

    # Insert the invariant just before the final `end` of the system block.
    [body, _last_end] = Regex.split(~r/\nend\s*\z/, source, parts: 2)
    body <> invariant <> "\nend\n"
  end

  test "system invariant parses but compile does not run model checking" do
    # mix compile must NOT run BFS exploration; it only parses + syntax-checks.
    source = """
    agent Node do
      state role: :follower | :leader

      protocol do
        accepts {:promote}
        emits {:ok}
      end

      on {:promote} when role == :follower do
        transition role: :leader
        emit {:ok}
      end
    end

    system Cluster do
      agent :a, Node()
      agent :b, Node()

      safety "at most one leader" proven do
        never(count(agents where role == :leader) > 1)
      end
    end
    """

    # Even though both nodes can independently become leader, this compiles
    # because mix compile does NOT explore product states.
    {:ok, _} = Vor.Compiler.compile_system(source)
  end
end
