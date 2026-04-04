defmodule Vor.Fixes.Gap011Test do
  use ExUnit.Case

  test "agent starts without name (backward compatible)" do
    source = """
    agent Anon do
      protocol do
        accepts {:ping}
        emits {:pong}
      end

      on {:ping} do
        emit {:pong}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])
    assert {:pong, %{}} = GenServer.call(pid, {:ping, %{}})
    GenServer.stop(pid)
  end

  test "agent starts with local name via Vor start_link" do
    source = """
    agent LocalNamed do
      protocol do
        accepts {:ping}
        emits {:pong}
      end

      on {:ping} do
        emit {:pong}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    # Call the Vor-generated start_link which handles name extraction
    {:ok, pid} = result.module.start_link([name: {:local, :test_gap011_agent}])
    assert {:pong, %{}} = GenServer.call(:test_gap011_agent, {:ping, %{}})
    GenServer.stop(pid)
  end

  test "agent starts with via Registry name via Vor start_link" do
    source = """
    agent RegistryNamed do
      protocol do
        accepts {:ping}
        emits {:pong}
      end

      on {:ping} do
        emit {:pong}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, _} = Registry.start_link(keys: :unique, name: Gap011TestRegistry)
    {:ok, pid} = result.module.start_link([name: {:via, Registry, {Gap011TestRegistry, :agent_1}}])

    [{found_pid, _}] = Registry.lookup(Gap011TestRegistry, :agent_1)
    assert found_pid == pid
    assert {:pong, %{}} = GenServer.call({:via, Registry, {Gap011TestRegistry, :agent_1}}, {:ping, %{}})
    GenServer.stop(pid)
  end

  test "multiple instances with different names and params via Vor start_link" do
    source = """
    agent Vnode(vnode_id: integer) do
      protocol do
        accepts {:id}
        emits {:vnode, id: integer}
      end

      on {:id} do
        emit {:vnode, id: vnode_id}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, _} = Registry.start_link(keys: :unique, name: VnodeGap011Registry)

    pids = for i <- 1..5 do
      name = {:via, Registry, {VnodeGap011Registry, :"vnode_#{i}"}}
      {:ok, pid} = result.module.start_link([vnode_id: i, name: name])
      pid
    end

    for i <- 1..5 do
      name = {:via, Registry, {VnodeGap011Registry, :"vnode_#{i}"}}
      assert {:vnode, %{id: ^i}} = GenServer.call(name, {:id, %{}})
    end

    Enum.each(pids, &GenServer.stop/1)
  end

  test "gen_statem agent with name" do
    source = """
    agent StatemNamed do
      state phase: :idle | :active

      protocol do
        accepts {:ping}
        emits {:pong}
      end

      on {:ping} when phase == :idle do
        emit {:pong}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = :gen_statem.start_link({:local, :test_gap011_statem}, result.module, [], [])
    assert {:pong, %{}} = :gen_statem.call(:test_gap011_statem, {:ping, %{}})
    :gen_statem.stop(pid)
  end

  test "existing system block agents still work" do
    source = """
    agent SysAgent do
      protocol do
        accepts {:ping}
        emits {:pong}
      end

      on {:ping} do
        emit {:pong}
      end
    end

    system Gap011Sys do
      agent :a, SysAgent()
    end
    """

    {:ok, result} = Vor.Compiler.compile_system_and_load(source)
    {:ok, sup_pid} = result.system.start_link.()

    registry = result.system.registry
    [{pid, _}] = Registry.lookup(registry, :a)
    assert {:pong, %{}} = GenServer.call(pid, {:ping, %{}})

    Supervisor.stop(sup_pid)
  end
end
