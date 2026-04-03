defmodule Vor.Features.EveryTest do
  use ExUnit.Case

  test "every block fires periodically (gen_server)" do
    source = """
    agent Ticker do
      state tick_count: integer

      protocol do
        accepts {:get}
        emits {:ticks, count: integer}
      end

      every 100 do
        transition tick_count: tick_count + 1
      end

      on {:get} do
        emit {:ticks, count: tick_count}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])
    Process.sleep(350)
    {:ticks, %{count: count}} = GenServer.call(pid, {:get, %{}})
    assert count >= 2 and count <= 5
    GenServer.stop(pid)
  end

  test "every block with parameter interval" do
    source = """
    agent ConfigTicker(interval_ms: integer) do
      state tick_count: integer

      protocol do
        accepts {:get}
        emits {:ticks, count: integer}
      end

      every interval_ms do
        transition tick_count: tick_count + 1
      end

      on {:get} do
        emit {:ticks, count: tick_count}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [interval_ms: 50])
    Process.sleep(275)
    {:ticks, %{count: count}} = GenServer.call(pid, {:get, %{}})
    assert count >= 3
    GenServer.stop(pid)
  end

  test "every block in gen_statem" do
    source = """
    agent StatemTicker do
      state phase: :running | :stopped
      state tick_count: integer

      protocol do
        accepts {:get}
        emits {:ticks, count: integer}
      end

      every 100 do
        transition tick_count: tick_count + 1
      end

      on {:get} when phase == :running do
        emit {:ticks, count: tick_count}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = :gen_statem.start_link(result.module, [], [])
    Process.sleep(350)
    {:ticks, %{count: count}} = :gen_statem.call(pid, {:get, %{}})
    assert count >= 2
    :gen_statem.stop(pid)
  end

  test "multiple every blocks" do
    source = """
    agent MultiTimer do
      state fast_count: integer
      state slow_count: integer

      protocol do
        accepts {:get}
        emits {:counts, fast: integer, slow: integer}
      end

      every 50 do
        transition fast_count: fast_count + 1
      end

      every 150 do
        transition slow_count: slow_count + 1
      end

      on {:get} do
        emit {:counts, fast: fast_count, slow: slow_count}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])
    Process.sleep(350)
    {:counts, %{fast: fast, slow: slow}} = GenServer.call(pid, {:get, %{}})
    assert fast > slow
    assert fast >= 4
    assert slow >= 1
    GenServer.stop(pid)
  end

  test "every doesn't interfere with normal handlers" do
    source = """
    agent TickAndHandle do
      state tick_count: integer
      state handle_count: integer

      protocol do
        accepts {:action}
        accepts {:get}
        emits {:ok}
        emits {:counts, ticks: integer, handles: integer}
      end

      every 100 do
        transition tick_count: tick_count + 1
      end

      on {:action} do
        transition handle_count: handle_count + 1
        emit {:ok}
      end

      on {:get} do
        emit {:counts, ticks: tick_count, handles: handle_count}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])
    GenServer.call(pid, {:action, %{}})
    GenServer.call(pid, {:action, %{}})
    GenServer.call(pid, {:action, %{}})
    Process.sleep(250)
    {:counts, %{ticks: ticks, handles: handles}} = GenServer.call(pid, {:get, %{}})
    assert handles == 3
    assert ticks >= 1
    GenServer.stop(pid)
  end

  test "every with broadcast in system" do
    source = """
    agent Beacon(interval_ms: integer) do
      protocol do
        accepts {:get_beacon}
        sends {:ping, value: integer}
        emits {:ok}
      end

      every interval_ms do
        broadcast {:ping, value: 1}
      end

      on {:get_beacon} do
        emit {:ok}
      end
    end

    agent Listener do
      state ping_count: integer

      protocol do
        accepts {:ping, value: integer}
        accepts {:get_pings}
        emits {:pings, count: integer}
      end

      on {:ping, value: V} do
        transition ping_count: ping_count + 1
      end

      on {:get_pings} do
        emit {:pings, count: ping_count}
      end
    end

    system BeaconTest do
      agent :beacon, Beacon(interval_ms: 100)
      agent :listener, Listener()
      connect :beacon -> :listener
    end
    """

    {:ok, result} = Vor.Compiler.compile_system_and_load(source)
    {:ok, sup_pid} = result.system.start_link.()

    Process.sleep(350)

    registry = result.system.registry
    [{lpid, _}] = Registry.lookup(registry, :listener)
    {:pings, %{count: count}} = GenServer.call(lpid, {:get_pings, %{}})
    assert count >= 2, "Expected at least 2 pings, got #{count}"

    Supervisor.stop(sup_pid)
  end
end
