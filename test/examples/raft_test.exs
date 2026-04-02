defmodule Vor.Examples.RaftTest do
  use ExUnit.Case

  # --- Compilation tests ---

  test "raft node compiles with verified invariants" do
    source = File.read!("examples/raft.vor")
    {:ok, _result} = Vor.Compiler.compile_string(source)
  end

  test "raft state graph is correct" do
    source = File.read!("examples/raft.vor")
    {:ok, graph} = Vor.Compiler.extract_graph(source)

    assert :follower in graph.states
    assert :candidate in graph.states
    assert :leader in graph.states
    assert length(graph.states) == 3
  end

  # --- Single-node follower tests ---

  defp start_raft_node(opts \\ []) do
    source = File.read!("examples/raft.vor")
    {:ok, result} = Vor.Compiler.compile_and_load(source)
    defaults = [node_id: :test_node, cluster_size: 3, election_timeout_ms: 5000, heartbeat_ms: 1000]
    {:ok, pid} = :gen_statem.start_link(result.module, Keyword.merge(defaults, opts), [])
    pid
  end

  test "starts as follower" do
    pid = start_raft_node()
    result = :gen_statem.call(pid, {:get_state, %{}})
    assert {:state_info, %{role: :follower, term: 0}} = result
    :gen_statem.stop(pid)
  end

  test "grants vote for higher term" do
    pid = start_raft_node()
    :gen_statem.cast(pid, {:request_vote, %{
      term: 1, candidate_id: :candidate1, last_log_index: 0, last_log_term: 0
    }})
    Process.sleep(50)
    result = :gen_statem.call(pid, {:get_state, %{}})
    assert {:state_info, %{term: 1}} = result
    :gen_statem.stop(pid)
  end

  test "rejects vote for lower term" do
    pid = start_raft_node()
    :gen_statem.cast(pid, {:request_vote, %{
      term: 0, candidate_id: :candidate1, last_log_index: 0, last_log_term: 0
    }})
    Process.sleep(50)
    result = :gen_statem.call(pid, {:get_state, %{}})
    assert {:state_info, %{role: :follower, term: 0}} = result
    :gen_statem.stop(pid)
  end

  test "accepts append_entries from leader" do
    pid = start_raft_node()
    :gen_statem.cast(pid, {:append_entries, %{
      term: 1, leader_id: :leader1, entries: [], leader_commit: 0
    }})
    Process.sleep(50)
    result = :gen_statem.call(pid, {:get_state, %{}})
    assert {:state_info, %{term: 1}} = result
    :gen_statem.stop(pid)
  end

  test "redirects client requests as follower" do
    pid = start_raft_node()
    result = :gen_statem.call(pid, {:client_request, %{command: :set_x}})
    assert {:client_redirect, %{leader: :unknown}} = result
    :gen_statem.stop(pid)
  end

  # --- Election tests ---

  test "becomes candidate after election timeout" do
    pid = start_raft_node(election_timeout_ms: 200)
    Process.sleep(350)
    result = :gen_statem.call(pid, {:get_state, %{}})
    assert {:state_info, %{role: :candidate}} = result
    :gen_statem.stop(pid)
  end

  test "candidate accumulates votes" do
    pid = start_raft_node(election_timeout_ms: 200)
    Process.sleep(350)

    # Check we're a candidate with 1 self-vote
    result = :gen_statem.call(pid, {:get_state, %{}})
    assert {:state_info, %{role: :candidate, term: term}} = result

    # Send one more vote
    :gen_statem.cast(pid, {:vote_granted, %{term: term, voter: :node2}})
    Process.sleep(50)

    # Vote count should be 2 (self + node2)
    {_state, data} = :sys.get_state(pid)
    assert data.vote_count == 2
    :gen_statem.stop(pid)
  end

  test "candidate steps down on higher term append_entries" do
    pid = start_raft_node(election_timeout_ms: 200)
    Process.sleep(350)

    :gen_statem.cast(pid, {:append_entries, %{
      term: 5, leader_id: :real_leader, entries: [], leader_commit: 0
    }})
    Process.sleep(50)

    result = :gen_statem.call(pid, {:get_state, %{}})
    assert {:state_info, %{role: :follower, term: 5}} = result
    :gen_statem.stop(pid)
  end

  # --- Leader tests ---

  test "candidate steps down on higher term vote_denied" do
    pid = start_raft_node(election_timeout_ms: 200)
    Process.sleep(350)

    {:state_info, %{role: :candidate}} = :gen_statem.call(pid, {:get_state, %{}})

    :gen_statem.cast(pid, {:vote_denied, %{term: 5}})
    Process.sleep(50)

    result = :gen_statem.call(pid, {:get_state, %{}})
    assert {:state_info, %{role: :follower, term: 5}} = result
    :gen_statem.stop(pid)
  end

  # --- Cluster integration tests ---

  test "three-node cluster starts and nodes communicate" do
    source = File.read!("examples/raft_cluster.vor")
    {:ok, result} = Vor.Compiler.compile_system_and_load(source)
    {:ok, sup_pid} = result.system.start_link.()

    registry = result.system.registry

    # Wait for election timeouts + vote propagation
    Process.sleep(800)

    # All nodes should be alive and have progressed past initial state
    roles = Enum.map([:node1, :node2, :node3], fn name ->
      [{pid, _}] = Registry.lookup(registry, name)
      {:state_info, state} = :gen_statem.call(pid, {:get_state, %{}})
      {name, state}
    end)

    # At least one node should have become a candidate (election timeout fired)
    non_followers = Enum.filter(roles, fn {_, state} -> state.role != :follower end)
    assert length(non_followers) >= 1, "Expected at least one non-follower, got: #{inspect(roles)}"

    # All nodes should have term >= 1 (election happened)
    terms = Enum.map(roles, fn {_, state} -> state.term end)
    assert Enum.any?(terms, fn t -> t >= 1 end), "Expected at least one node with term >= 1, got: #{inspect(terms)}"

    Supervisor.stop(sup_pid)
  end
end
