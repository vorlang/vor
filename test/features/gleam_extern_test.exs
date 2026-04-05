defmodule Vor.Features.GleamExternTest do
  use ExUnit.Case

  test "extern gleam block parses with slash-separated modules" do
    source = """
    agent GleamTest do
      extern gleam do
        vordb/counter.empty() :: term
        vordb/counter.increment(counter: term, node_id: binary, amount: integer) :: term
        vordb/counter.value(counter: term) :: integer
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

  test "gleam extern call in handler body compiles" do
    source = """
    agent GleamCall do
      extern gleam do
        vordb/counter.value(counter: term) :: integer
      end

      state store: map

      protocol do
        accepts {:get_value, key: atom}
        emits {:result, value: integer}
      end

      on {:get_value, key: K} do
        counter = map_get(store, K, 0)
        val = vordb/counter.value(counter: counter)
        emit {:result, value: val}
      end
    end
    """

    {:ok, _} = Vor.Compiler.compile_string(source)
  end

  test "gleam extern generates correct @-separated module atom in IR" do
    source = """
    agent GleamIR do
      extern gleam do
        my/module.my_function(x: integer) :: integer
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

    {:ok, tokens} = Vor.Lexer.tokenize(source)
    {:ok, ast} = Vor.Parser.parse(tokens)
    {:ok, ir} = Vor.Lowering.lower(ast)

    extern = hd(ir.externs)
    assert {:gleam_mod, :"my@module"} = extern.module
    assert :my_function = extern.function
  end

  test "deeply nested gleam module path" do
    source = """
    agent DeepPath do
      extern gleam do
        vordb/storage/rocks.get(key: binary) :: term
      end

      protocol do
        accepts {:get, key: binary}
        emits {:result, value: term}
      end

      on {:get, key: K} do
        result = vordb/storage/rocks.get(key: K)
        emit {:result, value: result}
      end
    end
    """

    {:ok, tokens} = Vor.Lexer.tokenize(source)
    {:ok, ast} = Vor.Parser.parse(tokens)
    {:ok, ir} = Vor.Lowering.lower(ast)

    extern = hd(ir.externs)
    assert {:gleam_mod, :"vordb@storage@rocks"} = extern.module
  end

  test "gleam and erlang externs in same agent" do
    source = """
    agent MixedExterns do
      extern gleam do
        vordb/counter.empty() :: term
      end

      extern do
        Erlang.erlang.system_time(unit: atom) :: integer
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

  test "gleam and elixir externs in same agent" do
    source = """
    agent MixedExterns2 do
      extern gleam do
        vordb/counter.empty() :: term
      end

      extern do
        Vor.TestHelpers.Echo.reflect(value: term) :: term
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

  test "existing extern blocks unchanged" do
    source = """
    agent BackCompat do
      extern do
        Vor.TestHelpers.Echo.reflect(value: term) :: term
      end

      protocol do
        accepts {:echo, msg: term}
        emits {:result, value: term}
      end

      on {:echo, msg: M} do
        result = Vor.TestHelpers.Echo.reflect(value: M)
        emit {:result, value: result}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])
    assert {:result, %{value: :hello}} = GenServer.call(pid, {:echo, %{msg: :hello}})
    GenServer.stop(pid)
  end

  test "gleam extern without binding in handler" do
    source = """
    agent GleamNoBind do
      extern gleam do
        vordb/counter.increment(counter: term, node_id: binary, amount: integer) :: term
      end

      state data: integer

      protocol do
        accepts {:go, amount: integer}
        emits {:ok}
      end

      on {:go, amount: A} do
        vordb/counter.increment(counter: data, node_id: :test, amount: A)
        emit {:ok}
      end
    end
    """

    {:ok, _} = Vor.Compiler.compile_string(source)
  end
end
