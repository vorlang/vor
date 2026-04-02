defmodule Vor.System.ProtocolTest do
  use ExUnit.Case

  test "matching protocols pass composition check" do
    source = """
    agent Sender do
      protocol do
        accepts {:go, id: term}
        sends {:data, value: integer}
        emits {:ok, id: term}
      end

      on {:go, id: I} do
        send :receiver {:data, value: I}
        emit {:ok, id: I}
      end
    end

    agent Receiver do
      protocol do
        accepts {:data, value: integer}
      end

      on {:data, value: V} do
      end
    end

    system TestSystem do
      agent :sender, Sender()
      agent :receiver, Receiver()
      connect :sender -> :receiver
    end
    """

    {:ok, _result} = Vor.Compiler.compile_system(source)
  end

  test "mismatched field names produce compile error" do
    source = """
    agent Sender do
      protocol do
        accepts {:go, id: term}
        sends {:data, value: integer}
        emits {:ok, id: term}
      end

      on {:go, id: I} do
        send :receiver {:data, value: I}
        emit {:ok, id: I}
      end
    end

    agent Receiver do
      protocol do
        accepts {:data, amount: integer}
      end

      on {:data, amount: A} do
      end
    end

    system TestSystem do
      agent :sender, Sender()
      agent :receiver, Receiver()
      connect :sender -> :receiver
    end
    """

    assert {:error, %{type: :protocol_mismatch}} = Vor.Compiler.compile_system(source)
  end

  test "send to unconnected agent produces compile error" do
    source = """
    agent Sender do
      protocol do
        accepts {:go, id: term}
        sends {:data, value: integer}
        emits {:ok, id: term}
      end

      on {:go, id: I} do
        send :receiver {:data, value: I}
        emit {:ok, id: I}
      end
    end

    agent Receiver do
      protocol do
        accepts {:data, value: integer}
      end

      on {:data, value: V} do
      end
    end

    system TestSystem do
      agent :sender, Sender()
      agent :receiver, Receiver()
    end
    """

    assert {:error, %{type: :send_not_connected}} = Vor.Compiler.compile_system(source)
  end

  test "standalone agent without system works as before" do
    source = """
    agent Solo do
      protocol do
        accepts {:hello, name: term}
        emits {:hi, name: term}
      end

      on {:hello, name: N} do
        emit {:hi, name: N}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])
    assert {:hi, %{name: "world"}} = GenServer.call(pid, {:hello, %{name: "world"}})
    GenServer.stop(pid)
  end

  test "system with no connections compiles" do
    source = """
    agent AgentA do
      protocol do
        accepts {:hello, id: term}
        emits {:hi, id: term}
      end

      on {:hello, id: I} do
        emit {:hi, id: I}
      end
    end

    agent AgentB do
      protocol do
        accepts {:hello, id: term}
        emits {:hi, id: term}
      end

      on {:hello, id: I} do
        emit {:hi, id: I}
      end
    end

    system TwoAgents do
      agent :a, AgentA()
      agent :b, AgentB()
    end
    """

    {:ok, _result} = Vor.Compiler.compile_system(source)
  end
end
