defmodule Vor.Features.ListLiteralsTest do
  use ExUnit.Case

  test "empty list in emit" do
    source = """
    agent EmptyList do
      protocol do
        accepts {:get}
        emits {:result, items: list}
      end

      on {:get} do
        emit {:result, items: []}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])

    assert {:result, %{items: []}} = GenServer.call(pid, {:get, %{}})
    GenServer.stop(pid)
  end

  test "populated list with integers" do
    source = """
    agent IntList do
      protocol do
        accepts {:get}
        emits {:result, items: list}
      end

      on {:get} do
        emit {:result, items: [1, 2, 3]}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])

    assert {:result, %{items: [1, 2, 3]}} = GenServer.call(pid, {:get, %{}})
    GenServer.stop(pid)
  end

  test "list with atoms" do
    source = """
    agent AtomList do
      protocol do
        accepts {:get}
        emits {:result, tags: list}
      end

      on {:get} do
        emit {:result, tags: [:alpha, :beta]}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])

    assert {:result, %{tags: [:alpha, :beta]}} = GenServer.call(pid, {:get, %{}})
    GenServer.stop(pid)
  end

  test "list with variables" do
    source = """
    agent VarList do
      protocol do
        accepts {:echo, a: integer, b: integer}
        emits {:result, items: list}
      end

      on {:echo, a: A, b: B} do
        emit {:result, items: [A, B]}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])

    assert {:result, %{items: [10, 20]}} = GenServer.call(pid, {:echo, %{a: 10, b: 20}})
    GenServer.stop(pid)
  end

  test "list state field defaults to empty list" do
    source = """
    agent ListDefault do
      state items: list

      protocol do
        accepts {:get}
        emits {:items, values: list}
      end

      on {:get} do
        emit {:items, values: items}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])

    assert {:items, %{values: []}} = GenServer.call(pid, {:get, %{}})
    GenServer.stop(pid)
  end

  test "list in send" do
    source = """
    agent ListSender do
      protocol do
        accepts {:go}
        sends {:data, batch: list}
        emits {:ok}
      end

      on {:go} do
        send :target {:data, batch: [1, 2, 3]}
        emit {:ok}
      end
    end

    agent ListReceiver do
      state received: list

      protocol do
        accepts {:data, batch: list}
        accepts {:get}
        emits {:batch, items: list}
      end

      on {:data, batch: B} do
        transition received: B
      end

      on {:get} do
        emit {:batch, items: received}
      end
    end

    system ListSendTest do
      agent :sender, ListSender()
      agent :target, ListReceiver()
      connect :sender -> :target
    end
    """

    {:ok, result} = Vor.Compiler.compile_system_and_load(source)
    {:ok, sup_pid} = result.system.start_link.()

    registry = result.system.registry
    [{pid, _}] = Registry.lookup(registry, :sender)
    GenServer.call(pid, {:go, %{}})

    Process.sleep(100)

    [{rpid, _}] = Registry.lookup(registry, :target)
    assert {:batch, %{items: [1, 2, 3]}} = GenServer.call(rpid, {:get, %{}})

    Supervisor.stop(sup_pid)
  end
end
