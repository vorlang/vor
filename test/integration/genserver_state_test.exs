defmodule Vor.Integration.GenserverStateTest do
  use ExUnit.Case

  test "gen_server agent with integer state field" do
    source = """
    agent Counter do
      state count: integer

      protocol do
        accepts {:increment, id: term}
        accepts {:get, id: term}
        emits {:count, value: integer}
        emits {:ok, id: term}
      end

      on {:increment, id: I} do
        transition count: count + 1
        emit {:ok, id: I}
      end

      on {:get, id: I} do
        emit {:count, value: count}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    assert result.ir.behaviour == :gen_server

    {:ok, pid} = GenServer.start_link(result.module, [])

    GenServer.call(pid, {:increment, %{id: 1}})
    GenServer.call(pid, {:increment, %{id: 2}})
    GenServer.call(pid, {:increment, %{id: 3}})

    result = GenServer.call(pid, {:get, %{id: 0}})
    assert {:count, %{value: 3}} = result
    GenServer.stop(pid)
  end

  test "gen_server with multiple state fields" do
    source = """
    agent MultiField do
      state count: integer
      state label: atom
      state active: atom

      protocol do
        accepts {:activate, name: atom}
        accepts {:status, id: term}
        emits {:ok, id: term}
        emits {:info, count: integer, label: atom, active: atom}
      end

      on {:activate, name: N} do
        transition count: count + 1
        transition label: N
        transition active: :yes
        emit {:ok, id: N}
      end

      on {:status, id: I} do
        emit {:info, count: count, label: label, active: active}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    assert result.ir.behaviour == :gen_server

    {:ok, pid} = GenServer.start_link(result.module, [])

    GenServer.call(pid, {:activate, %{name: :primary}})
    result = GenServer.call(pid, {:status, %{id: 0}})
    assert {:info, %{count: 1, label: :primary, active: :yes}} = result
    GenServer.stop(pid)
  end

  test "gen_server with both params and state fields" do
    source = """
    agent Bounded(max: integer) do
      state count: integer

      protocol do
        accepts {:increment, id: term}
        accepts {:get, id: term}
        emits {:ok, remaining: integer}
        emits {:full, id: term}
        emits {:count, value: integer}
      end

      on {:increment, id: I} do
        if count < max do
          transition count: count + 1
          emit {:ok, remaining: max - count}
        else
          emit {:full, id: I}
        end
      end

      on {:get, id: I} do
        emit {:count, value: count}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [max: 3])

    assert {:ok, %{remaining: 2}} = GenServer.call(pid, {:increment, %{id: 1}})  # 3 - 1
    assert {:ok, %{remaining: 1}} = GenServer.call(pid, {:increment, %{id: 2}})  # 3 - 2
    assert {:ok, %{remaining: 0}} = GenServer.call(pid, {:increment, %{id: 3}})  # 3 - 3
    assert {:full, _} = GenServer.call(pid, {:increment, %{id: 4}})
    GenServer.stop(pid)
  end

  test "state fields initialize to type defaults" do
    source = """
    agent Defaults do
      state n: integer
      state label: atom

      protocol do
        accepts {:check, id: term}
        emits {:state, n: integer, label: atom}
      end

      on {:check, id: I} do
        emit {:state, n: n, label: label}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])

    result = GenServer.call(pid, {:check, %{id: 0}})
    assert {:state, %{n: 0, label: nil}} = result
    GenServer.stop(pid)
  end

  test "native rate limiter with gen_server state" do
    source = """
    agent NativeRateLimiter(max_requests: integer) do
      state count: integer

      protocol do
        accepts {:request, client: binary}
        emits {:ok, remaining: integer}
        emits {:rejected, id: term}
      end

      on {:request, client: C} do
        if count < max_requests do
          transition count: count + 1
          emit {:ok, remaining: max_requests - count}
        else
          emit {:rejected, id: C}
        end
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [max_requests: 3])

    assert {:ok, %{remaining: 2}} = GenServer.call(pid, {:request, %{client: "alice"}})  # 3 - 1
    assert {:ok, %{remaining: 1}} = GenServer.call(pid, {:request, %{client: "alice"}})  # 3 - 2
    assert {:ok, %{remaining: 0}} = GenServer.call(pid, {:request, %{client: "alice"}})  # 3 - 3
    assert {:rejected, _} = GenServer.call(pid, {:request, %{client: "alice"}})
    GenServer.stop(pid)
  end

  test "gen_server without state fields still works" do
    source = File.read!("test/fixtures/echo.vor")
    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])
    assert {:pong, %{payload: "hello"}} = GenServer.call(pid, {:ping, %{payload: "hello"}})
    GenServer.stop(pid)
  end
end
