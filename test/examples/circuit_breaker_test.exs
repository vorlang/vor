defmodule Vor.Examples.CircuitBreakerTest do
  use ExUnit.Case

  setup do
    source = File.read!("examples/circuit_breaker.vor")
    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = :gen_statem.start_link(result.module, [], [])
    %{pid: pid, result: result}
  end

  test "starts in closed state", %{pid: pid} do
    assert {:closed, _} = :sys.get_state(pid)
  end

  test "forwards requests when closed", %{pid: pid} do
    :gen_statem.cast(pid, {:request, %{payload: "hello"}})
    Process.sleep(10)
    # Still closed after forwarding
    assert {:closed, _} = :sys.get_state(pid)
  end

  test "trips to open state", %{pid: pid} do
    :gen_statem.cast(pid, {:trip, %{reason: :too_many_errors}})
    Process.sleep(10)
    assert {:open, _} = :sys.get_state(pid)
  end

  test "timer moves open to half_open", %{pid: pid} do
    :gen_statem.cast(pid, {:trip, %{reason: :errors}})
    Process.sleep(10)
    assert {:open, _} = :sys.get_state(pid)

    # Simulate timer firing
    send(pid, :timer_recovery_fired)
    Process.sleep(10)
    assert {:half_open, _} = :sys.get_state(pid)
  end

  test "probe success closes circuit", %{pid: pid} do
    # Drive to half_open
    :gen_statem.cast(pid, {:trip, %{reason: :errors}})
    Process.sleep(10)
    send(pid, :timer_recovery_fired)
    Process.sleep(10)
    assert {:half_open, _} = :sys.get_state(pid)

    # Probe succeeds
    :gen_statem.cast(pid, {:probe_success, %{result: :healthy}})
    Process.sleep(10)
    assert {:closed, _} = :sys.get_state(pid)
  end

  test "probe failure reopens circuit", %{pid: pid} do
    # Drive to half_open
    :gen_statem.cast(pid, {:trip, %{reason: :errors}})
    Process.sleep(10)
    send(pid, :timer_recovery_fired)
    Process.sleep(10)
    assert {:half_open, _} = :sys.get_state(pid)

    # Probe fails
    :gen_statem.cast(pid, {:probe_failure, %{reason: :still_down}})
    Process.sleep(10)
    assert {:open, _} = :sys.get_state(pid)
  end

  test "reset from open returns to closed", %{pid: pid} do
    :gen_statem.cast(pid, {:trip, %{reason: :errors}})
    Process.sleep(10)
    :gen_statem.cast(pid, {:reset, %{source: :manual}})
    Process.sleep(10)
    assert {:closed, _} = :sys.get_state(pid)
  end

  test "has correct graph", %{result: result} do
    graph = result.graph
    assert graph != nil
    assert :closed in graph.states
    assert :open in graph.states
    assert :half_open in graph.states
    assert graph.initial_state == :closed
  end

  test "open state cannot emit ok", %{result: result} do
    open_emits = Map.get(result.graph.emit_map, :open, [])
    refute :ok in open_emits
    assert :rejected in open_emits
  end
end
