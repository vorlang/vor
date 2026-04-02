defmodule Vor.Broadcast.BroadcastTest do
  use ExUnit.Case

  # --- Positive tests ---

  test "broadcast parses and compiles in system" do
    source = """
    agent Sender do
      protocol do
        accepts {:go}
        sends {:data, value: integer}
        emits {:ok}
      end

      on {:go} do
        broadcast {:data, value: 42}
        emit {:ok}
      end
    end

    agent Receiver do
      protocol do
        accepts {:data, value: integer}
      end

      on {:data, value: V} do
      end
    end

    system BcastCompile do
      agent :sender, Sender()
      agent :r1, Receiver()
      agent :r2, Receiver()
      connect :sender -> :r1
      connect :sender -> :r2
    end
    """

    {:ok, _modules} = Vor.Compiler.compile_system(source)
  end

  test "broadcast with send and emit in same handler compiles" do
    source = """
    agent Hybrid do
      protocol do
        accepts {:do_all}
        sends {:broadcast_msg, data: integer}
        sends {:direct_msg, data: integer}
        emits {:done}
      end

      on {:do_all} do
        broadcast {:broadcast_msg, data: 1}
        send :specific {:direct_msg, data: 2}
        emit {:done}
      end
    end

    agent Receiver do
      protocol do
        accepts {:broadcast_msg, data: integer}
        accepts {:direct_msg, data: integer}
      end

      on {:broadcast_msg, data: D} do
      end

      on {:direct_msg, data: D} do
      end
    end

    system HybridCompile do
      agent :hybrid, Hybrid()
      agent :specific, Receiver()
      agent :other, Receiver()
      connect :hybrid -> :specific
      connect :hybrid -> :other
    end
    """

    {:ok, _modules} = Vor.Compiler.compile_system(source)
  end

  # --- Negative tests ---

  test "broadcast with undeclared message tag fails compilation" do
    source = """
    agent BadBroadcast do
      protocol do
        accepts {:go}
        sends {:data, value: integer}
        emits {:ok}
      end

      on {:go} do
        broadcast {:unknown, value: 42}
        emit {:ok}
      end
    end

    agent Receiver do
      protocol do
        accepts {:data, value: integer}
      end

      on {:data, value: V} do
      end
    end

    system BadCheck do
      agent :sender, BadBroadcast()
      agent :r1, Receiver()
      connect :sender -> :r1
    end
    """

    assert {:error, _} = Vor.Compiler.compile_system(source)
  end

  # --- Runtime tests ---

  test "broadcast delivers to all connected agents" do
    source = """
    agent Announcer do
      protocol do
        accepts {:announce}
        sends {:notification, value: integer}
        emits {:sent}
      end

      on {:announce} do
        broadcast {:notification, value: 99}
        emit {:sent}
      end
    end

    agent Listener do
      state got: integer

      protocol do
        accepts {:notification, value: integer}
        accepts {:check}
        emits {:result, got: integer}
      end

      on {:notification, value: V} do
        transition got: V
      end

      on {:check} do
        emit {:result, got: got}
      end
    end

    system BroadcastDeliver do
      agent :announcer, Announcer()
      agent :listener1, Listener()
      agent :listener2, Listener()
      agent :listener3, Listener()
      connect :announcer -> :listener1
      connect :announcer -> :listener2
      connect :announcer -> :listener3
    end
    """

    {:ok, result} = Vor.Compiler.compile_system_and_load(source)
    {:ok, sup_pid} = result.system.start_link.()

    registry = result.system.registry

    [{announcer_pid, _}] = Registry.lookup(registry, :announcer)
    assert {:sent, %{}} = GenServer.call(announcer_pid, {:announce, %{}})

    Process.sleep(100)

    # All three listeners should have received the broadcast
    Enum.each([:listener1, :listener2, :listener3], fn name ->
      [{pid, _}] = Registry.lookup(registry, name)
      assert {:result, %{got: 99}} = GenServer.call(pid, {:check, %{}})
    end)

    Supervisor.stop(sup_pid)
  end

  test "broadcast to no connections is a safe no-op" do
    source = """
    agent Alone do
      protocol do
        accepts {:go}
        sends {:ping}
        emits {:ok}
      end

      on {:go} do
        broadcast {:ping}
        emit {:ok}
      end
    end

    system AloneSystem do
      agent :alone, Alone()
    end
    """

    {:ok, result} = Vor.Compiler.compile_system_and_load(source)
    {:ok, sup_pid} = result.system.start_link.()

    registry = result.system.registry

    [{pid, _}] = Registry.lookup(registry, :alone)
    assert {:ok, %{}} = GenServer.call(pid, {:go, %{}})

    Supervisor.stop(sup_pid)
  end

  test "broadcast with send and emit in same handler at runtime" do
    source = """
    agent Hybrid do
      protocol do
        accepts {:do_all}
        sends {:broadcast_msg, data: integer}
        sends {:direct_msg, data: integer}
        emits {:done}
      end

      on {:do_all} do
        broadcast {:broadcast_msg, data: 1}
        send :specific {:direct_msg, data: 2}
        emit {:done}
      end
    end

    agent Receiver do
      state broadcast_count: integer
      state direct_count: integer

      protocol do
        accepts {:broadcast_msg, data: integer}
        accepts {:direct_msg, data: integer}
        accepts {:counts}
        emits {:status, bc: integer, dc: integer}
      end

      on {:broadcast_msg, data: D} do
        transition broadcast_count: broadcast_count + 1
      end

      on {:direct_msg, data: D} do
        transition direct_count: direct_count + 1
      end

      on {:counts} do
        emit {:status, bc: broadcast_count, dc: direct_count}
      end
    end

    system HybridRuntime do
      agent :hybrid, Hybrid()
      agent :specific, Receiver()
      agent :other, Receiver()
      connect :hybrid -> :specific
      connect :hybrid -> :other
    end
    """

    {:ok, result} = Vor.Compiler.compile_system_and_load(source)
    {:ok, sup_pid} = result.system.start_link.()

    registry = result.system.registry

    [{hybrid_pid, _}] = Registry.lookup(registry, :hybrid)
    GenServer.call(hybrid_pid, {:do_all, %{}})

    Process.sleep(100)

    # :specific gets both broadcast and direct
    [{specific_pid, _}] = Registry.lookup(registry, :specific)
    assert {:status, %{bc: 1, dc: 1}} = GenServer.call(specific_pid, {:counts, %{}})

    # :other gets only broadcast
    [{other_pid, _}] = Registry.lookup(registry, :other)
    assert {:status, %{bc: 1, dc: 0}} = GenServer.call(other_pid, {:counts, %{}})

    Supervisor.stop(sup_pid)
  end

  test "existing send still works unchanged" do
    source = """
    agent Sender do
      protocol do
        accepts {:go, value: integer}
        sends {:data, value: integer}
        emits {:sent}
      end

      on {:go, value: V} do
        send :receiver {:data, value: V}
        emit {:sent}
      end
    end

    agent Receiver do
      state last: integer

      protocol do
        accepts {:data, value: integer}
        accepts {:check}
        emits {:last, value: integer}
      end

      on {:data, value: V} do
        transition last: V
      end

      on {:check} do
        emit {:last, value: last}
      end
    end

    system BackwardCompat do
      agent :sender, Sender()
      agent :receiver, Receiver()
      connect :sender -> :receiver
    end
    """

    {:ok, result} = Vor.Compiler.compile_system_and_load(source)
    {:ok, sup_pid} = result.system.start_link.()

    registry = result.system.registry

    [{sender_pid, _}] = Registry.lookup(registry, :sender)
    assert {:sent, %{}} = GenServer.call(sender_pid, {:go, %{value: 7}})

    Process.sleep(50)

    [{receiver_pid, _}] = Registry.lookup(registry, :receiver)
    assert {:last, %{value: 7}} = GenServer.call(receiver_pid, {:check, %{}})

    Supervisor.stop(sup_pid)
  end
end
