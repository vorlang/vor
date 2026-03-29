defmodule Vor.Integration.EchoAgentTest do
  use ExUnit.Case

  test "echo agent handles ping/pong end-to-end" do
    source = File.read!("test/fixtures/echo.vor")
    {:ok, result} = Vor.Compiler.compile_and_load(source)

    assert result.module == Vor.Agent.Echo

    {:ok, pid} = GenServer.start_link(result.module, [])
    assert is_pid(pid)

    response = GenServer.call(pid, {:ping, %{payload: "hello"}})
    assert {:pong, %{payload: "hello"}} = response

    GenServer.stop(pid)
  end

  test "echo agent handles different payloads" do
    source = File.read!("test/fixtures/echo.vor")
    {:ok, result} = Vor.Compiler.compile_and_load(source)

    {:ok, pid} = GenServer.start_link(result.module, [])

    assert {:pong, %{payload: 42}} = GenServer.call(pid, {:ping, %{payload: 42}})
    assert {:pong, %{payload: [1, 2, 3]}} = GenServer.call(pid, {:ping, %{payload: [1, 2, 3]}})
    assert {:pong, %{payload: nil}} = GenServer.call(pid, {:ping, %{payload: nil}})

    # Unhandled message returns error
    assert {:error, :unhandled} = GenServer.call(pid, {:unknown, %{payload: "test"}})

    GenServer.stop(pid)
  end

  test "compile_string works the same as compile_file" do
    source = File.read!("test/fixtures/echo.vor")
    {:ok, result1} = Vor.Compiler.compile_string(source)
    {:ok, result2} = Vor.Compiler.compile_file("test/fixtures/echo.vor")

    assert result1.module == result2.module
  end
end
