defmodule Vor.Fixes.KeywordParamsTest do
  use ExUnit.Case

  test "extern parameter named 'state'" do
    source = """
    agent KeywordParam do
      extern gleam do
        my/module.process(state: term, value: integer) :: term
      end

      state store: map

      protocol do
        accepts {:go, value: integer}
        emits {:result, value: term}
      end

      on {:go, value: V} do
        result = my/module.process(state: store, value: V)
        emit {:result, value: result}
      end
    end
    """

    {:ok, _} = Vor.Compiler.compile_string(source)
  end

  test "extern parameter named 'protocol'" do
    source = """
    agent KeywordParam2 do
      extern do
        Vor.TestHelpers.Echo.reflect(protocol: term) :: term
      end

      protocol do
        accepts {:go}
        emits {:result, value: term}
      end

      on {:go} do
        result = Vor.TestHelpers.Echo.reflect(protocol: :test)
        emit {:result, value: result}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])
    assert {:result, %{value: :test}} = GenServer.call(pid, {:go, %{}})
    GenServer.stop(pid)
  end

  test "extern parameter named 'transition'" do
    source = """
    agent KeywordParam3 do
      extern gleam do
        my/module.apply_transition(transition: term, target: atom) :: term
      end

      protocol do
        accepts {:ping}
        emits {:pong}
      end

      on {:ping} do
        emit {:pong}
      end
    end
    """

    {:ok, _} = Vor.Compiler.compile_string(source)
  end

  test "extern parameter named 'emit' and 'broadcast'" do
    source = """
    agent KeywordParam4 do
      extern gleam do
        my/module.handle(emit: term, broadcast: term) :: term
      end

      protocol do
        accepts {:ping}
        emits {:pong}
      end

      on {:ping} do
        emit {:pong}
      end
    end
    """

    {:ok, _} = Vor.Compiler.compile_string(source)
  end
end
