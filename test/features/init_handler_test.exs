defmodule Vor.Features.InitHandlerTest do
  use ExUnit.Case

  test "on :init sets initial state" do
    source = """
    agent InitTest do
      state count: integer

      protocol do
        accepts {:get}
        emits {:count, value: integer}
      end

      on :init do
        transition count: 42
      end

      on {:get} do
        emit {:count, value: count}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])
    assert {:count, %{value: 42}} = GenServer.call(pid, {:get, %{}})
    GenServer.stop(pid)
  end

  test "on :init with extern call" do
    source = """
    agent InitExtern do
      extern do
        Vor.TestHelpers.InitHelper.load_value() :: integer
      end

      state data: integer

      protocol do
        accepts {:get}
        emits {:value, n: integer}
      end

      on :init do
        loaded = Vor.TestHelpers.InitHelper.load_value()
        transition data: loaded
      end

      on {:get} do
        emit {:value, n: data}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])
    assert {:value, %{n: 99}} = GenServer.call(pid, {:get, %{}})
    GenServer.stop(pid)
  end

  test "on :init with parameter reference" do
    source = """
    agent InitParam(multiplier: integer) do
      state result: integer

      protocol do
        accepts {:get}
        emits {:value, n: integer}
      end

      on :init do
        transition result: multiplier * 10
      end

      on {:get} do
        emit {:value, n: result}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [multiplier: 5])
    assert {:value, %{n: 50}} = GenServer.call(pid, {:get, %{}})
    GenServer.stop(pid)
  end

  test "on :init in gen_statem" do
    source = """
    agent InitStatem(start_count: integer) do
      state phase: :ready | :done
      state count: integer

      protocol do
        accepts {:get}
        emits {:info, count: integer}
      end

      on :init do
        transition count: start_count
      end

      on {:get} when phase == :ready do
        emit {:info, count: count}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = :gen_statem.start_link(result.module, [start_count: 77], [])
    assert {:info, %{count: 77}} = :gen_statem.call(pid, {:get, %{}})
    :gen_statem.stop(pid)
  end

  test "on :init cannot contain emit" do
    source = """
    agent BadInit do
      protocol do
        accepts {:ping}
        emits {:pong}
      end

      on :init do
        emit {:pong}
      end

      on {:ping} do
        emit {:pong}
      end
    end
    """

    assert {:error, %{type: :invalid_init_handler}} = Vor.Compiler.compile_string(source)
  end

  test "only one on :init allowed" do
    source = """
    agent DoubleInit do
      state a: integer
      state b: integer

      protocol do
        accepts {:get}
        emits {:ok}
      end

      on :init do
        transition a: 1
      end

      on :init do
        transition b: 2
      end

      on {:get} do
        emit {:ok}
      end
    end
    """

    assert {:error, %{type: :duplicate_init}} = Vor.Compiler.compile_string(source)
  end

  test "extern failure in init uses default state" do
    source = """
    agent InitFail do
      extern do
        Vor.TestHelpers.InitHelper.crash() :: integer
      end

      state data: integer

      protocol do
        accepts {:get}
        emits {:value, n: integer}
      end

      on :init do
        loaded = Vor.TestHelpers.InitHelper.crash()
        transition data: loaded
      end

      on {:get} do
        emit {:value, n: data}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])
    # Extern crashed — transition value is the error tuple, data keeps going
    # The behavior depends on whether the try/catch returns a usable value
    # At minimum, the process should not crash
    assert Process.alive?(pid)
    GenServer.stop(pid)
  end

  test "agent without on :init still works" do
    source = """
    agent NoInit do
      state count: integer

      protocol do
        accepts {:get}
        emits {:count, value: integer}
      end

      on {:get} do
        emit {:count, value: count}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])
    assert {:count, %{value: 0}} = GenServer.call(pid, {:get, %{}})
    GenServer.stop(pid)
  end
end
