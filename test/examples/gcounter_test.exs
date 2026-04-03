defmodule Vor.Examples.GCounterTest do
  use ExUnit.Case

  defp start_gcounter(node_id, sync_interval) do
    source = File.read!("examples/gcounter.vor")
    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [node_id: node_id, sync_interval_ms: sync_interval])
    pid
  end

  # --- Compilation ---

  test "gcounter compiles" do
    source = File.read!("examples/gcounter.vor")
    {:ok, _} = Vor.Compiler.compile_string(source)
  end

  # --- Single-node behavior ---

  test "single node starts with zero" do
    pid = start_gcounter(:test, 10_000)
    assert {:total, %{value: 0}} = GenServer.call(pid, {:value, %{}})
    GenServer.stop(pid)
  end

  test "single node increments correctly" do
    pid = start_gcounter(:test, 10_000)
    GenServer.call(pid, {:increment, %{}})
    GenServer.call(pid, {:increment, %{}})
    GenServer.call(pid, {:increment, %{}})
    assert {:total, %{value: 3}} = GenServer.call(pid, {:value, %{}})
    GenServer.stop(pid)
  end

  test "merge with remote state takes max" do
    pid = start_gcounter(:node_a, 10_000)
    GenServer.call(pid, {:increment, %{}})
    GenServer.call(pid, {:increment, %{}})

    GenServer.cast(pid, {:sync, %{remote_counts: %{node_b: 5}}})
    Process.sleep(50)

    assert {:total, %{value: 7}} = GenServer.call(pid, {:value, %{}})
    GenServer.stop(pid)
  end

  test "merge is idempotent" do
    pid = start_gcounter(:node_a, 10_000)
    GenServer.call(pid, {:increment, %{}})

    remote = %{node_b: 3}
    GenServer.cast(pid, {:sync, %{remote_counts: remote}})
    Process.sleep(50)
    GenServer.cast(pid, {:sync, %{remote_counts: remote}})
    Process.sleep(50)
    GenServer.cast(pid, {:sync, %{remote_counts: remote}})
    Process.sleep(50)

    assert {:total, %{value: 4}} = GenServer.call(pid, {:value, %{}})
    GenServer.stop(pid)
  end

  test "merge takes max per key" do
    pid = start_gcounter(:node_a, 10_000)
    for _ <- 1..5, do: GenServer.call(pid, {:increment, %{}})

    # Remote claims node_a=3 (stale) and node_b=10
    GenServer.cast(pid, {:sync, %{remote_counts: %{node_a: 3, node_b: 10}}})
    Process.sleep(50)

    # node_a stays at 5 (max 5,3), node_b=10
    assert {:total, %{value: 15}} = GenServer.call(pid, {:value, %{}})
    GenServer.stop(pid)
  end

  # --- Cluster convergence ---

  test "three-node cluster converges after gossip" do
    source = File.read!("examples/gcounter_cluster.vor")
    {:ok, result} = Vor.Compiler.compile_system_and_load(source)
    {:ok, sup_pid} = result.system.start_link.()

    registry = result.system.registry
    [{n1, _}] = Registry.lookup(registry, :node1)
    [{n2, _}] = Registry.lookup(registry, :node2)
    [{n3, _}] = Registry.lookup(registry, :node3)

    # Increment on different nodes
    for _ <- 1..3, do: GenServer.call(n1, {:increment, %{}})
    for _ <- 1..2, do: GenServer.call(n2, {:increment, %{}})
    for _ <- 1..5, do: GenServer.call(n3, {:increment, %{}})

    # Wait for gossip rounds
    Process.sleep(1000)

    # All nodes should report 3 + 2 + 5 = 10
    {:total, %{value: t1}} = GenServer.call(n1, {:value, %{}})
    {:total, %{value: t2}} = GenServer.call(n2, {:value, %{}})
    {:total, %{value: t3}} = GenServer.call(n3, {:value, %{}})

    assert t1 == 10, "Node1 got #{t1}, expected 10"
    assert t2 == 10, "Node2 got #{t2}, expected 10"
    assert t3 == 10, "Node3 got #{t3}, expected 10"

    Supervisor.stop(sup_pid)
  end

  test "counter never decreases" do
    source = File.read!("examples/gcounter_cluster.vor")
    {:ok, result} = Vor.Compiler.compile_system_and_load(source)
    {:ok, sup_pid} = result.system.start_link.()

    registry = result.system.registry
    [{n1, _}] = Registry.lookup(registry, :node1)

    for _ <- 1..5, do: GenServer.call(n1, {:increment, %{}})
    Process.sleep(500)

    {:total, %{value: v1}} = GenServer.call(n1, {:value, %{}})
    assert v1 >= 5

    for _ <- 1..3, do: GenServer.call(n1, {:increment, %{}})
    Process.sleep(500)

    {:total, %{value: v2}} = GenServer.call(n1, {:value, %{}})
    assert v2 >= v1

    Supervisor.stop(sup_pid)
  end
end
