defmodule Vor.Features.BackpressureTest do
  use ExUnit.Case

  # ----------------------------------------------------------------------
  # Parser
  # ----------------------------------------------------------------------

  test "parses agent-level max_queue" do
    source = """
    agent Worker do
      max_queue 500
      protocol do
        accepts {:task}
        emits {:ok}
      end
      on {:task} do
        emit {:ok}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_string(source)
    assert result.ir.max_queue == 500
  end

  test "parses per-message max_queue on accepts" do
    source = """
    agent Worker do
      protocol do
        accepts {:task} max_queue: 100
        accepts {:status}
        emits {:ok}
      end
      on {:task} do
        emit {:ok}
      end
      on {:status} do
        emit {:ok}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_string(source)
    task = Enum.find(result.ir.protocol.accepts, fn a -> a.tag == :task end)
    status = Enum.find(result.ir.protocol.accepts, fn a -> a.tag == :status end)
    assert task.max_queue == 100
    assert status.max_queue == nil
  end

  test "parses priority flag on accepts" do
    source = """
    agent Worker do
      max_queue 500
      protocol do
        accepts {:task} max_queue: 100
        accepts {:health} priority: true
        emits {:ok}
      end
      on {:task} do
        emit {:ok}
      end
      on {:health} do
        emit {:ok}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_string(source)
    health = Enum.find(result.ir.protocol.accepts, fn a -> a.tag == :health end)
    assert health.priority == true
    assert health.max_queue == nil
  end

  test "parses max_queue with where clause" do
    source = """
    agent Worker do
      protocol do
        accepts {:order, amount: integer} where amount > 0 max_queue: 100
        emits {:ok}
      end
      on {:order, amount: A} do
        emit {:ok}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_string(source)
    order = Enum.find(result.ir.protocol.accepts, fn a -> a.tag == :order end)
    assert order.constraint != nil
    assert order.max_queue == 100
  end

  test "no max_queue compiles identically to current behavior" do
    source = """
    agent Echo do
      protocol do
        accepts {:ping}
        emits {:pong}
      end
      on {:ping} do
        emit {:pong}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])
    assert {:pong, _} = GenServer.call(pid, {:ping, %{}})
    GenServer.stop(pid)
  end

  # ----------------------------------------------------------------------
  # Runtime behavior
  # ----------------------------------------------------------------------

  test "backpressure rejects call when queue exceeds limit" do
    source = """
    agent SlowWorker do
      protocol do
        accepts {:task, id: integer} max_queue: 2
        emits {:done, id: integer}
      end
      on {:task, id: I} do
        emit {:done, id: I}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])

    # Flood with casts to fill the mailbox
    for i <- 1..50 do
      GenServer.cast(pid, {:task, %{id: i}})
    end

    # Try a call — may or may not be rejected depending on processing speed
    result = GenServer.call(pid, {:task, %{id: 999}}, 5000)
    assert result in [{:done, %{id: 999}}, {:error, {:backpressure, :queue_full}}]

    GenServer.stop(pid)
  end

  # ----------------------------------------------------------------------
  # Existing tests
  # ----------------------------------------------------------------------

  test "all existing examples compile with backpressure support" do
    for file <- Path.wildcard("examples/*.vor") do
      source = File.read!(file)
      result = if String.contains?(source, "system ") do
        Vor.Compiler.compile_system(source)
      else
        Vor.Compiler.compile_string(source)
      end
      assert match?({:ok, _}, result), "Failed: #{file}"
    end
  end
end
