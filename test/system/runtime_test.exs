defmodule Vor.System.RuntimeTest do
  use ExUnit.Case

  test "system supervisor starts and registers all agents" do
    source = """
    agent Greeter do
      protocol do
        accepts {:hello}
        emits {:hi}
      end

      on {:hello} do
        emit {:hi}
      end
    end

    agent Counter do
      state count: integer

      protocol do
        accepts {:get}
        emits {:count, value: integer}
      end

      on {:get} do
        emit {:count, value: count}
      end
    end

    system TestSys do
      agent :greeter, Greeter()
      agent :counter, Counter()
    end
    """

    {:ok, result} = Vor.Compiler.compile_system_and_load(source)
    {:ok, sup_pid} = result.system.start_link.()

    registry = result.system.registry

    [{g_pid, _}] = Registry.lookup(registry, :greeter)
    [{c_pid, _}] = Registry.lookup(registry, :counter)

    assert Process.alive?(g_pid)
    assert Process.alive?(c_pid)
    assert {:hi, %{}} = GenServer.call(g_pid, {:hello, %{}})
    assert {:count, %{value: 0}} = GenServer.call(c_pid, {:get, %{}})

    Supervisor.stop(sup_pid)
  end

  test "send delivers message between agents" do
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

    system SendTest do
      agent :sender, Sender()
      agent :receiver, Receiver()
      connect :sender -> :receiver
    end
    """

    {:ok, result} = Vor.Compiler.compile_system_and_load(source)
    {:ok, sup_pid} = result.system.start_link.()

    registry = result.system.registry

    [{sender_pid, _}] = Registry.lookup(registry, :sender)
    assert {:sent, %{}} = GenServer.call(sender_pid, {:go, %{value: 42}})

    Process.sleep(50)

    [{receiver_pid, _}] = Registry.lookup(registry, :receiver)
    assert {:last, %{value: 42}} = GenServer.call(receiver_pid, {:check, %{}})

    Supervisor.stop(sup_pid)
  end

  test "three-agent pipeline" do
    source = """
    agent Source do
      protocol do
        accepts {:produce, n: integer}
        sends {:item, value: integer}
        emits {:ok}
      end

      on {:produce, n: N} do
        send :transformer {:item, value: N}
        emit {:ok}
      end
    end

    agent Transformer do
      protocol do
        accepts {:item, value: integer}
        sends {:result, doubled: integer}
      end

      on {:item, value: V} do
        send :sink {:result, doubled: V + V}
      end
    end

    agent Sink do
      state total: integer

      protocol do
        accepts {:result, doubled: integer}
        accepts {:get_total}
        emits {:total, value: integer}
      end

      on {:result, doubled: D} do
        transition total: total + D
      end

      on {:get_total} do
        emit {:total, value: total}
      end
    end

    system PipelineTest do
      agent :source, Source()
      agent :transformer, Transformer()
      agent :sink, Sink()
      connect :source -> :transformer
      connect :transformer -> :sink
    end
    """

    {:ok, result} = Vor.Compiler.compile_system_and_load(source)
    {:ok, sup_pid} = result.system.start_link.()

    registry = result.system.registry

    [{source_pid, _}] = Registry.lookup(registry, :source)
    GenServer.call(source_pid, {:produce, %{n: 5}})
    GenServer.call(source_pid, {:produce, %{n: 10}})

    Process.sleep(100)

    [{sink_pid, _}] = Registry.lookup(registry, :sink)
    assert {:total, %{value: 30}} = GenServer.call(sink_pid, {:get_total, %{}})

    Supervisor.stop(sup_pid)
  end

  test "parameterized agents in system receive params" do
    source = """
    agent Greeter(greeting: binary) do
      protocol do
        accepts {:hello}
        emits {:reply, message: binary}
      end

      on {:hello} do
        emit {:reply, message: greeting}
      end
    end

    system ParamTest do
      agent :greeter, Greeter(greeting: "Howdy")
    end
    """

    {:ok, result} = Vor.Compiler.compile_system_and_load(source)
    {:ok, sup_pid} = result.system.start_link.()

    registry = result.system.registry

    [{pid, _}] = Registry.lookup(registry, :greeter)
    assert {:reply, %{message: "Howdy"}} = GenServer.call(pid, {:hello, %{}})

    Supervisor.stop(sup_pid)
  end
end
