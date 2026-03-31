defmodule Vor.Integration.ExternTest do
  use ExUnit.Case

  test "agent can call extern Elixir function" do
    source = File.read!("test/fixtures/extern_echo.vor")
    {:ok, result} = Vor.Compiler.compile_and_load(source)

    assert result.module == Vor.Agent.ExternEcho

    {:ok, pid} = GenServer.start_link(result.module, [])
    response = GenServer.call(pid, {:transform, %{text: "hello"}})
    assert {:result, %{text: "HELLO"}} = response

    GenServer.stop(pid)
  end

  test "extern declarations are in the IR" do
    source = File.read!("test/fixtures/extern_echo.vor")
    {:ok, result} = Vor.Compiler.compile_string(source)

    assert [extern] = result.ir.externs
    assert extern.module == VorTest.Helpers
    assert extern.function == :upcase
    assert extern.trusted == false
  end

  test "extern call with Erlang module" do
    source = File.read!("test/fixtures/extern_erlang.vor")
    {:ok, result} = Vor.Compiler.compile_and_load(source)

    assert result.module == Vor.Agent.ExternErlang

    {:ok, pid} = GenServer.start_link(result.module, [])
    {:time, %{value: ts}} = GenServer.call(pid, {:get_time, %{req: :now}})
    assert is_integer(ts)

    GenServer.stop(pid)
  end

  test "extern crash returns vor_extern_error" do
    source = """
    agent ExternCrash do
      extern do
        VorTest.Helpers.explode(text: binary) :: binary
      end

      protocol do
        accepts {:crash, text: binary}
        emits {:result, text: binary}
      end

      on {:crash, text: T} do
        result = VorTest.Helpers.explode(text: T)
        emit {:result, text: result}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])

    # The extern raises, so the reply will contain the error tuple
    response = GenServer.call(pid, {:crash, %{text: "boom"}})
    assert {:result, %{text: {:vor_extern_error, :error, %RuntimeError{}, _stacktrace}}} = response

    GenServer.stop(pid)
  end
end
