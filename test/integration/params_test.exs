defmodule Vor.Integration.ParamsTest do
  use ExUnit.Case

  test "parameterized agent receives config at init" do
    source = File.read!("test/fixtures/greeter.vor")
    {:ok, result} = Vor.Compiler.compile_and_load(source)

    {:ok, pid} = GenServer.start_link(result.module, [greeting: "Howdy"])
    response = GenServer.call(pid, {:hello, %{name: "James"}})
    assert {:reply, %{message: "Howdy"}} = response

    GenServer.stop(pid)
  end

  test "parameterized agent with different config" do
    source = File.read!("test/fixtures/greeter.vor")
    {:ok, result} = Vor.Compiler.compile_and_load(source)

    {:ok, pid} = GenServer.start_link(result.module, [greeting: "Hola"])
    response = GenServer.call(pid, {:hello, %{name: "Maria"}})
    assert {:reply, %{message: "Hola"}} = response

    GenServer.stop(pid)
  end

  test "parameterized agent IR has params" do
    source = File.read!("test/fixtures/greeter.vor")
    {:ok, result} = Vor.Compiler.compile_string(source)

    assert [{:greeting, :binary}] = result.ir.params
  end

  test "non-parameterized agents still work" do
    source = File.read!("test/fixtures/echo.vor")
    {:ok, result} = Vor.Compiler.compile_and_load(source)

    assert result.ir.params == []

    {:ok, pid} = GenServer.start_link(result.module, [])
    assert {:pong, %{payload: "test"}} = GenServer.call(pid, {:ping, %{payload: "test"}})

    GenServer.stop(pid)
  end
end
