defmodule Vor.Examples.LockTest do
  use ExUnit.Case

  defp start_lock(timeout_ms \\ 5000) do
    source = File.read!("examples/lock.vor")
    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = :gen_statem.start_link(result.module, [lock_timeout_ms: timeout_ms], [])
    pid
  end

  # --- Compilation ---

  test "lock compiles with verified invariant" do
    source = File.read!("examples/lock.vor")
    {:ok, _} = Vor.Compiler.compile_string(source)
  end

  test "state graph shows free and held" do
    source = File.read!("examples/lock.vor")
    {:ok, graph} = Vor.Compiler.extract_graph(source)
    assert :free in graph.states
    assert :held in graph.states
    assert length(graph.states) == 2
  end

  # --- Basic operations ---

  test "lock starts free" do
    pid = start_lock()
    result = :gen_statem.call(pid, {:status, %{}})
    assert {:status_info, %{phase: :free, holder: :none, queue_length: 0}} = result
    :gen_statem.stop(pid)
  end

  test "acquire when free grants immediately" do
    pid = start_lock()
    assert {:grant, %{client: :alice}} = :gen_statem.call(pid, {:acquire, %{client: :alice}})
    assert {:status_info, %{phase: :held, holder: :alice}} = :gen_statem.call(pid, {:status, %{}})
    :gen_statem.stop(pid)
  end

  test "acquire when held queues the client" do
    pid = start_lock()
    :gen_statem.call(pid, {:acquire, %{client: :alice}})
    assert {:queued, %{position: 1}} = :gen_statem.call(pid, {:acquire, %{client: :bob}})
    assert {:queued, %{position: 2}} = :gen_statem.call(pid, {:acquire, %{client: :carol}})
    assert {:status_info, %{phase: :held, holder: :alice, queue_length: 2}} = :gen_statem.call(pid, {:status, %{}})
    :gen_statem.stop(pid)
  end

  test "release when free returns not_holder" do
    pid = start_lock()
    assert {:not_holder, %{}} = :gen_statem.call(pid, {:release, %{client: :alice}})
    :gen_statem.stop(pid)
  end

  test "release with empty queue goes free" do
    pid = start_lock()
    :gen_statem.call(pid, {:acquire, %{client: :alice}})
    :gen_statem.call(pid, {:release, %{client: :alice}})
    assert {:status_info, %{phase: :free}} = :gen_statem.call(pid, {:status, %{}})
    :gen_statem.stop(pid)
  end

  test "release with waiters grants to next in FIFO order" do
    pid = start_lock()
    :gen_statem.call(pid, {:acquire, %{client: :alice}})
    :gen_statem.call(pid, {:acquire, %{client: :bob}})
    :gen_statem.call(pid, {:acquire, %{client: :carol}})

    # Release alice — bob should get it
    :gen_statem.call(pid, {:release, %{client: :alice}})
    assert {:status_info, %{phase: :held, holder: :bob, queue_length: 1}} = :gen_statem.call(pid, {:status, %{}})

    # Release bob — carol should get it
    :gen_statem.call(pid, {:release, %{client: :bob}})
    assert {:status_info, %{phase: :held, holder: :carol, queue_length: 0}} = :gen_statem.call(pid, {:status, %{}})

    # Release carol — should go free
    :gen_statem.call(pid, {:release, %{client: :carol}})
    assert {:status_info, %{phase: :free}} = :gen_statem.call(pid, {:status, %{}})

    :gen_statem.stop(pid)
  end

  # --- Liveness timeout ---

  test "lock times out and releases automatically" do
    pid = start_lock(200)
    :gen_statem.call(pid, {:acquire, %{client: :alice}})
    Process.sleep(350)
    assert {:status_info, %{phase: :free}} = :gen_statem.call(pid, {:status, %{}})
    :gen_statem.stop(pid)
  end

  # --- Stress ---

  test "50 rapid acquire/release cycles" do
    pid = start_lock()

    for i <- 1..50 do
      client = :"client_#{i}"
      :gen_statem.call(pid, {:acquire, %{client: client}})
    end

    # Release them all in order
    :gen_statem.call(pid, {:release, %{client: :client_1}})
    for i <- 2..50 do
      client = :"client_#{i}"
      :gen_statem.call(pid, {:release, %{client: client}})
    end

    assert {:status_info, %{phase: :free}} = :gen_statem.call(pid, {:status, %{}})
    :gen_statem.stop(pid)
  end
end
