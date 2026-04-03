defmodule Vor.TutorialTest do
  use ExUnit.Case

  test "step 1 — echo agent" do
    source = File.read!("tutorial/step1.vor")
    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])
    assert {:pong, %{payload: "hello"}} = GenServer.call(pid, {:ping, %{payload: "hello"}})
    GenServer.stop(pid)
  end

  test "step 2 — counter with state" do
    source = File.read!("tutorial/step2.vor")
    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])
    GenServer.cast(pid, {:increment, %{}})
    GenServer.cast(pid, {:increment, %{}})
    GenServer.cast(pid, {:increment, %{}})
    Process.sleep(50)
    assert {:count, %{value: 3}} = GenServer.call(pid, {:get, %{}})
    GenServer.stop(pid)
  end

  test "step 3 — parameterized bounded counter" do
    source = File.read!("tutorial/step3.vor")
    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [max: 3])
    assert {:ok, %{remaining: 2}} = GenServer.call(pid, {:increment, %{}})
    assert {:ok, %{remaining: 1}} = GenServer.call(pid, {:increment, %{}})
    assert {:ok, %{remaining: 0}} = GenServer.call(pid, {:increment, %{}})
    assert {:full, %{}} = GenServer.call(pid, {:increment, %{}})
    GenServer.stop(pid)
  end

  test "step 4 — relations with solve" do
    source = File.read!("tutorial/step4.vor")
    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [default_max: 10])
    assert {:limit, %{max: 100}} = GenServer.call(pid, {:get_limit, %{client: :pro}})
    assert {:limit, %{max: 1000}} = GenServer.call(pid, {:get_limit, %{client: :enterprise}})
    GenServer.stop(pid)
  end

  test "step 5 — broken invariant fails compilation" do
    source = File.read!("tutorial/step5_broken.vor")
    assert {:error, _} = Vor.Compiler.compile_string(source)
  end

  test "step 5 — fixed gate with verified invariant" do
    source = File.read!("tutorial/step5_fixed.vor")
    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = :gen_statem.start_link(result.module, [], [])
    assert {:denied, %{}} = :gen_statem.call(pid, {:enter, %{}})
    assert {:opened, %{}} = :gen_statem.call(pid, {:open_gate, %{}})
    assert {:allowed, %{}} = :gen_statem.call(pid, {:enter, %{}})
    :gen_statem.stop(pid)
  end

  test "step 6 — liveness monitoring auto-closes gate" do
    source = File.read!("tutorial/step6.vor")
    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = :gen_statem.start_link(result.module, [auto_close_ms: 300], [])
    assert {:opened, %{}} = :gen_statem.call(pid, {:open_gate, %{}})
    Process.sleep(500)
    assert {:denied, %{}} = :gen_statem.call(pid, {:enter, %{}})
    :gen_statem.stop(pid)
  end

  test "step 7 — extern calls to ETS" do
    Vor.Examples.TutorialHelpers.reset()
    source = File.read!("tutorial/step7.vor")
    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [max_requests: 3, window_ms: 60_000])
    assert {:ok, %{remaining: 2}} = GenServer.call(pid, {:request, %{client: "alice"}})
    assert {:ok, %{remaining: 1}} = GenServer.call(pid, {:request, %{client: "alice"}})
    assert {:ok, %{remaining: 0}} = GenServer.call(pid, {:request, %{client: "alice"}})
    assert {:rejected, %{}} = GenServer.call(pid, {:request, %{client: "alice"}})
    assert {:ok, %{remaining: 2}} = GenServer.call(pid, {:request, %{client: "bob"}})
    GenServer.stop(pid)
  end

  test "step 8 — multi-agent pipeline" do
    source = File.read!("tutorial/step8.vor")
    {:ok, result} = Vor.Compiler.compile_system_and_load(source)
    {:ok, sup_pid} = result.system.start_link.()

    registry = result.system.registry
    [{producer_pid, _}] = Registry.lookup(registry, :producer)
    GenServer.call(producer_pid, {:produce, %{item: 10}})
    GenServer.call(producer_pid, {:produce, %{item: 20}})
    Process.sleep(100)

    [{consumer_pid, _}] = Registry.lookup(registry, :consumer)
    assert {:total, %{value: 30}} = GenServer.call(consumer_pid, {:get_total, %{}})

    Supervisor.stop(sup_pid)
  end

  # Compiler trace test
  test "compile with trace option produces output" do
    source = File.read!("tutorial/step1.vor")

    output = ExUnit.CaptureIO.capture_io(fn ->
      {:ok, _} = Vor.Compiler.compile_string(source, trace: true)
    end)

    assert String.contains?(output, "Vor Compiler Trace")
    assert String.contains?(output, "[lexer]")
    assert String.contains?(output, "[parser]")
    assert String.contains?(output, "[compile]")
    assert String.contains?(output, "Complete")
  end

  test "compile without trace produces no output" do
    source = File.read!("tutorial/step1.vor")

    output = ExUnit.CaptureIO.capture_io(fn ->
      {:ok, _} = Vor.Compiler.compile_string(source)
    end)

    assert output == ""
  end
end
