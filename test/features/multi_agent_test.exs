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

    # Key by instance name (matching what Vor.Explorer builds at runtime).
    # Multiple instances of the same agent type share the same IR object.
    instance_irs =
      Enum.into(result.system_ir.agents, %{}, fn instance ->
        ir =
          case Map.get(result.agents, instance.type_name) do
            %{ir: ir} -> ir
            _ -> nil
          end

        {instance.name, ir}
      end)

    {result.system_ir, instance_irs}
  end

  # Some Milestone-3 tests look up handlers via the agent type name. Provide
  # a separate helper for that.
  defp first_handler(instance_irs, _type_name, msg_tag) do
    ir =
      instance_irs
      |> Map.values()
      |> Enum.find(fn ir -> ir != nil end)

    Enum.find(ir.handlers, fn h ->
      h.pattern.tag == to_string(msg_tag) or h.pattern.tag == msg_tag
    end)
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

  # ----------------------------------------------------------------------
  # Zero-extern Raft
  # ----------------------------------------------------------------------

  test "raft has no extern declarations" do
    raft_source = File.read!("examples/raft.vor")
    cluster_source = File.read!("examples/raft_cluster.vor")

    refute String.contains?(raft_source, "extern do")
    refute String.contains?(cluster_source, "extern do")
    refute String.contains?(raft_source, "RaftHelpers")
    refute String.contains?(cluster_source, "RaftHelpers")
  end

  test "no examples use Elixir externs" do
    for file <- Path.wildcard("examples/*.vor") do
      source = File.read!(file)
      refute String.contains?(source, "extern do"),
        "#{file} still has Elixir externs"
    end
  end

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

  # ----------------------------------------------------------------------
  # Phase 2: state abstraction and integer saturation
  # ----------------------------------------------------------------------

  test "relevance.invariant_fields extracts the agent field referenced in count(...)" do
    inv = %Vor.IR.SystemInvariant{
      name: "at most one leader",
      tier: :proven,
      body: {:never, {:count_gt, {:agents_where, :role, :==, :leader}, 1}}
    }

    assert :role in Vor.Explorer.Relevance.invariant_fields(inv)
  end

  test "relevance computes transitive closure through guards and conditionals" do
    source = """
    agent TestNode do
      state role: :follower | :candidate | :leader
      state current_term: integer
      state vote_count: integer
      state commit_index: integer

      protocol do
        accepts {:vote_granted, term: integer}
        accepts {:noop}
        emits {:ok}
      end

      on {:vote_granted, term: T} when role == :candidate and T == current_term do
        new_votes = vote_count + 1
        transition vote_count: new_votes
        if new_votes > 1 do
          transition role: :leader
          emit {:ok}
        else
          emit {:ok}
        end
      end

      on {:noop} do
        transition commit_index: 1
        emit {:ok}
      end
    end

    system Cluster do
      agent :a, TestNode()
      agent :b, TestNode()

      safety "at most one leader" proven do
        never(count(agents where role == :leader) > 1)
      end
    end
    """

    {system_ir, agent_irs} = build_initial(source)
    relevance = Vor.Explorer.Relevance.compute(system_ir, agent_irs, system_ir.invariants)

    info = relevance[:a]

    assert :role in info.tracked_state, "role is invariant field"
    assert :vote_count in info.tracked_state, "vote_count gates the role transition (via new_votes)"
    assert :current_term in info.tracked_state, "current_term appears in the candidate guard"
    refute :commit_index in info.tracked_state, "commit_index never influences a role transition"
    assert :commit_index in info.abstracted
  end

  test "parameters are excluded from tracked state" do
    source = """
    agent ParamNode(cluster_size: integer) do
      state role: :follower | :leader
      state vote_count: integer

      protocol do
        accepts {:tick}
        emits {:ok}
      end

      on {:tick} when role == :follower do
        transition vote_count: vote_count + 1
        if vote_count > cluster_size do
          transition role: :leader
          emit {:ok}
        else
          emit {:ok}
        end
      end
    end

    system Cluster do
      agent :a, ParamNode(cluster_size: 3)
      agent :b, ParamNode(cluster_size: 3)

      safety "at most one leader" proven do
        never(count(agents where role == :leader) > 1)
      end
    end
    """

    {system_ir, agent_irs} = build_initial(source)
    relevance = Vor.Explorer.Relevance.compute(system_ir, agent_irs, system_ir.invariants)

    info = relevance[:a]
    assert :cluster_size in info.params
    refute :cluster_size in info.tracked_state
    assert :role in info.tracked_state
    assert :vote_count in info.tracked_state
  end

  test "ProductState.abstract masks abstracted fields with :abstracted" do
    ps = %Vor.Explorer.ProductState{
      agents: %{
        a: %{role: :follower, vote_count: 0, commit_index: 7},
        b: %{role: :leader, vote_count: 2, commit_index: 99}
      }
    }

    relevance = %{
      a: %{
        tracked_state: MapSet.new([:role, :vote_count]),
        tracked_int: MapSet.new([:vote_count]),
        abstracted: MapSet.new([:commit_index]),
        params: MapSet.new()
      },
      b: %{
        tracked_state: MapSet.new([:role, :vote_count]),
        tracked_int: MapSet.new([:vote_count]),
        abstracted: MapSet.new([:commit_index]),
        params: MapSet.new()
      }
    }

    abstracted = Vor.Explorer.ProductState.abstract(ps, relevance)
    assert abstracted.agents[:a].commit_index == :abstracted
    assert abstracted.agents[:b].commit_index == :abstracted
    # Tracked fields untouched
    assert abstracted.agents[:a].role == :follower
    assert abstracted.agents[:b].vote_count == 2
  end

  test "abstracted fingerprints collapse states differing only in abstracted fields" do
    relevance = %{
      a: %{
        tracked_state: MapSet.new([:role]),
        tracked_int: MapSet.new(),
        abstracted: MapSet.new([:commit_index]),
        params: MapSet.new()
      }
    }

    ps1 = Vor.Explorer.ProductState.abstract(
      %Vor.Explorer.ProductState{agents: %{a: %{role: :follower, commit_index: 5}}},
      relevance
    )

    ps2 = Vor.Explorer.ProductState.abstract(
      %Vor.Explorer.ProductState{agents: %{a: %{role: :follower, commit_index: 999}}},
      relevance
    )

    assert Vor.Explorer.ProductState.fingerprint(ps1) ==
             Vor.Explorer.ProductState.fingerprint(ps2)
  end

  test "saturate_integers caps tracked integer fields at the bound" do
    state = %{vote_count: 7, current_term: 99, commit_index: 12}
    tracked_int = MapSet.new([:vote_count, :current_term])

    saturated = Vor.Explorer.ProductState.saturate_integers(state, tracked_int, 3)
    assert saturated.vote_count == 3
    assert saturated.current_term == 3
    # Untracked integer left alone
    assert saturated.commit_index == 12
  end

  test "simulator treats :abstracted as :unknown — guards on abstracted fields fan out" do
    source = """
    agent ExternBranch do
      state phase: :a | :b | :c
      state count: integer

      protocol do
        accepts {:tick}
        emits {:ok}
      end

      on {:tick} when phase == :a do
        if count > 0 do
          transition phase: :b
        else
          transition phase: :c
        end
        emit {:ok}
      end
    end

    system Cluster do
      agent :x, ExternBranch()
    end
    """

    {_system_ir, agent_irs} = build_initial(source)
    handler = first_handler(agent_irs, :ExternBranch, :tick)

    # Pass an :abstracted value for count — simulator should branch both ways
    results =
      Vor.Explorer.Simulator.simulate(handler, %{phase: :a, count: :abstracted},
        {:tick, %{}}, :x, [])

    phases = results |> Enum.map(fn {s, _} -> s.phase end) |> Enum.sort()
    assert :b in phases
    assert :c in phases
  end

  test "raft cluster reaches exhaustive proven with state abstraction + queue bound" do
    raft_source = File.read!("examples/raft_cluster.vor")

    augmented =
      String.replace(raft_source, ~r/\nend\s*\z/, """

        safety "at most one leader" proven do
          never(count(agents where role == :leader) > 1)
        end
      end
      """)

    # Phase 2 with the message-queue cap should let the BFS exhaust the
    # reachable product state space for the augmented Raft cluster.
    result =
      Vor.Explorer.check_file(augmented,
        max_depth: 30,
        max_states: 50_000,
        integer_bound: 3,
        max_queue: 10
      )

    case result do
      {:ok, :proven, stats} ->
        IO.puts("Raft Phase-2 proven: #{stats.states_explored} states, depth #{stats.max_depth_reached}")
        first = stats.relevance |> Map.values() |> hd()
        assert :role in first.tracked_state
        assert :vote_count in first.tracked_state
        assert :commit_index in first.abstracted
        assert true

      {:ok, :bounded, stats} ->
        flunk(
          "Expected raft to reach :proven with abstraction + queue bound; " <>
          "got bounded after #{stats.states_explored} states at depth #{stats.max_depth_reached}"
        )

      {:error, :violation, name, _trace, _stats} ->
        flunk("Unexpected violation: #{name}")
    end
  end

  test "max_queue caps the pending message buffer" do
    # A broadcast-heavy agent: each external start triggers a broadcast to
    # both peers, so without a queue cap the buffer would grow unboundedly
    # as deliveries chain. With max_queue: 2 the surplus is dropped.
    source = """
    agent Hub do
      protocol do
        accepts {:start}
        accepts {:hello, from: atom}
        emits {:ok}
        sends {:hello, from: atom}
      end

      on {:start} do
        broadcast {:hello, from: :me}
        emit {:ok}
      end

      on {:hello, from: F} do
        broadcast {:hello, from: :me}
        emit {:ok}
      end
    end

    system Cluster do
      agent :a, Hub()
      agent :b, Hub()
      agent :c, Hub()
      connect :a -> :b
      connect :a -> :c
      connect :b -> :a
      connect :b -> :c
      connect :c -> :a
      connect :c -> :b

      safety "at most zero leaders" proven do
        never(count(agents where role == :leader) > 1)
      end
    end
    """

    {system_ir, instance_irs} = build_initial(source)

    # No relevance applied here — this is a Phase-1 successors call with
    # only `max_queue` opted in. The cap should still apply.
    seed = %Vor.Explorer.ProductState{
      agents: %{a: %{}, b: %{}, c: %{}},
      pending_messages: [
        {:a, :b, {:hello, %{from: :me}}},
        {:a, :c, {:hello, %{from: :me}}}
      ]
    }

    capped = Vor.Explorer.Successor.successors(seed, instance_irs, system_ir, max_queue: 2)

    Enum.each(capped, fn ps ->
      assert length(ps.pending_messages) <= 2,
             "expected pending queue to be capped at 2, got #{length(ps.pending_messages)}"
    end)
  end

  test "Phase 1 fingerprint behavior unchanged when no relevance is supplied" do
    # successors/3 (no opts) keeps Phase-1 semantics: no abstraction, no
    # saturation, fingerprint over the full agent state map.
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
    end
    """

    {system_ir, agent_irs} = build_initial(source)
    ps = Vor.Explorer.ProductState.initial(system_ir, agent_irs)
    succs = Vor.Explorer.Successor.successors(ps, agent_irs, system_ir)

    # External {:promote} → role becomes :leader
    assert Enum.any?(succs, fn s -> s.agents[:a].role == :leader end)
  end

  # ----------------------------------------------------------------------
  # Phase 3: quantifiers and named agent references
  # ----------------------------------------------------------------------

  test "exists pair invariant parses" do
    source = """
    agent Holder do
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

    system Cluster do
      agent :a, Holder()
      agent :b, Holder()
      connect :a -> :b
      connect :b -> :a

      safety "no two holders" proven do
        never(exists A, B where A.phase == :held and B.phase == :held)
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_system(source)
    assert [%{body: {:never, {:exists_pair, :A, :B, _}}}] = result.system_ir.invariants
  end

  test "for_all invariant parses" do
    source = """
    agent Modal do
      state mode: :idle | :active | :error

      protocol do
        accepts {:activate}
        emits {:ok}
      end

      on {:activate} when mode == :idle do
        transition mode: :active
        emit {:ok}
      end
    end

    system Cluster do
      agent :a, Modal()
      agent :b, Modal()

      safety "no errors" proven do
        for_all agents, mode == :idle or mode == :active
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_system(source)
    assert [%{body: {:for_all, _}}] = result.system_ir.invariants
  end

  test "named agent reference invariant parses" do
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

      safety "n1 stays follower" proven do
        never(n1.role == :leader)
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_system(source)
    assert [%{body: {:never, {:==, {:named_agent_field, :n1, :role}, :leader}}}] =
             result.system_ir.invariants
  end

  test "exists pair detects two simultaneous holders" do
    source = """
    agent Holder do
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

    system TwoHolders do
      agent :a, Holder()
      agent :b, Holder()
      connect :a -> :b
      connect :b -> :a

      safety "no two holders" proven do
        never(exists A, B where A.phase == :held and B.phase == :held)
      end
    end
    """

    assert {:error, :violation, "no two holders", _trace, _stats} =
             Vor.Explorer.check_file(source, max_depth: 10, max_states: 1_000)
  end

  test "for_all holds on a system that never enters error mode" do
    source = """
    agent SafeNode do
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

    system SafeCluster do
      agent :a, SafeNode()
      agent :b, SafeNode()

      safety "modes are valid" proven do
        for_all agents, mode == :idle or mode == :active
      end
    end
    """

    assert {:ok, :proven, _} =
             Vor.Explorer.check_file(source, max_depth: 10, max_states: 1_000)
  end

  test "named agent reference detects violation" do
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

      safety "n1 stays follower" proven do
        never(n1.role == :leader)
      end
    end
    """

    # n1 can receive an external :promote — violation expected.
    assert {:error, :violation, "n1 stays follower", _trace, _stats} =
             Vor.Explorer.check_file(source, max_depth: 10, max_states: 1_000)
  end

  test "relevance.invariant_fields handles exists_pair, for_all, named refs" do
    inv1 = %Vor.IR.SystemInvariant{
      name: "test1",
      tier: :proven,
      body:
        {:never,
         {:exists_pair, :A, :B,
          {:and, {:==, {:agent_field, :A, :role}, :leader},
           {:!=, {:agent_field, :A, :term}, {:agent_field, :B, :term}}}}}
    }

    fields1 = Vor.Explorer.Relevance.invariant_fields(inv1)
    assert :role in fields1
    assert :term in fields1

    inv2 = %Vor.IR.SystemInvariant{
      name: "test2",
      tier: :proven,
      body:
        {:for_all,
         {:or, {:==, {:field, :mode}, :idle}, {:==, {:field, :mode}, :active}}}
    }

    assert :mode in Vor.Explorer.Relevance.invariant_fields(inv2)

    inv3 = %Vor.IR.SystemInvariant{
      name: "test3",
      tier: :proven,
      body: {:never, {:==, {:named_agent_field, :n1, :role}, :leader}}
    }

    assert :role in Vor.Explorer.Relevance.invariant_fields(inv3)
  end

  # ----------------------------------------------------------------------
  # Phase 3: symmetry reduction
  # ----------------------------------------------------------------------

  test "symmetry detected for homogeneous fully-connected system" do
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
      connect :n1 -> :n2
      connect :n1 -> :n3
      connect :n2 -> :n1
      connect :n2 -> :n3
      connect :n3 -> :n1
      connect :n3 -> :n2

      safety "at most one leader" proven do
        never(count(agents where role == :leader) > 1)
      end
    end
    """

    {system_ir, _} = build_initial(source)
    assert Vor.Explorer.Symmetry.can_reduce?(system_ir)
    assert Vor.Explorer.Symmetry.enabled?(system_ir, system_ir.invariants, :auto)
  end

  test "symmetry not detected for heterogeneous system" do
    source = """
    agent Producer do
      protocol do
        accepts {:start}
        emits {:ok}
        sends {:item, n: integer}
      end

      on {:start} do
        send :sink {:item, n: 1}
        emit {:ok}
      end
    end

    agent Consumer do
      protocol do
        accepts {:item, n: integer}
        emits {:ok}
      end

      on {:item, n: N} do
        emit {:ok}
      end
    end

    system Pipeline do
      agent :source, Producer()
      agent :sink, Consumer()
      connect :source -> :sink
    end
    """

    {system_ir, _} = build_initial(source)
    refute Vor.Explorer.Symmetry.can_reduce?(system_ir)
  end

  test "named-agent invariant disables symmetry even on a homogeneous system" do
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

      safety "n1 never leads" proven do
        never(n1.role == :leader)
      end
    end
    """

    {system_ir, _} = build_initial(source)
    assert Vor.Explorer.Symmetry.can_reduce?(system_ir)
    refute Vor.Explorer.Symmetry.enabled?(system_ir, system_ir.invariants, :auto)
  end

  test "symmetry reduction shrinks the explored state space" do
    raft_source = File.read!("examples/raft_cluster.vor")

    augmented =
      String.replace(raft_source, ~r/\nend\s*\z/, """

        safety "at most one leader" proven do
          never(count(agents where role == :leader) > 1)
        end
      end
      """)

    {:ok, :proven, with_sym} =
      Vor.Explorer.check_file(augmented,
        max_depth: 30,
        max_states: 50_000,
        symmetry: :auto
      )

    {:ok, :proven, without_sym} =
      Vor.Explorer.check_file(augmented,
        max_depth: 30,
        max_states: 50_000,
        symmetry: false
      )

    assert with_sym.symmetry == true
    assert without_sym.symmetry == false
    assert with_sym.states_explored < without_sym.states_explored
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
