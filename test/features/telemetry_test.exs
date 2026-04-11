defmodule Vor.Features.TelemetryTest do
  use ExUnit.Case

  setup do
    # Ensure telemetry is enabled
    Application.put_env(:vor, :telemetry, true)
    :ok
  end

  test "agent start emits telemetry event (gen_server)" do
    source = """
    agent Simple do
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
    events = :ets.new(:test_events, [:bag, :public])

    :telemetry.attach("test-start", [:vor, :agent, :start], fn event, _m, metadata, _ ->
      :ets.insert(events, {event, metadata})
    end, nil)

    {:ok, pid} = GenServer.start_link(result.module, [])

    starts = :ets.lookup(events, [:vor, :agent, :start])
    assert length(starts) >= 1
    {_, metadata} = hd(starts)
    assert metadata.type == :gen_server

    :telemetry.detach("test-start")
    GenServer.stop(pid)
    :ets.delete(events)
  end

  test "agent start emits telemetry event (gen_statem)" do
    source = """
    agent Lock do
      state phase: :free | :held

      protocol do
        accepts {:acquire}
        emits {:ok}
      end

      on {:acquire} when phase == :free do
        transition phase: :held
        emit {:ok}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    events = :ets.new(:test_events, [:bag, :public])

    :telemetry.attach("test-statem-start", [:vor, :agent, :start], fn event, _m, metadata, _ ->
      :ets.insert(events, {event, metadata})
    end, nil)

    {:ok, pid} = :gen_statem.start_link(result.module, [], [])

    starts = :ets.lookup(events, [:vor, :agent, :start])
    assert length(starts) >= 1
    {_, metadata} = hd(starts)
    assert metadata.type == :gen_statem
    assert metadata.initial_state == :free

    :telemetry.detach("test-statem-start")
    :gen_statem.stop(pid)
    :ets.delete(events)
  end

  test "message received emits telemetry event" do
    source = """
    agent Echo do
      protocol do
        accepts {:ping, value: atom}
        emits {:pong, value: atom}
      end

      on {:ping, value: V} do
        emit {:pong, value: V}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    events = :ets.new(:test_events, [:bag, :public])

    :telemetry.attach("test-received", [:vor, :message, :received], fn event, _m, metadata, _ ->
      :ets.insert(events, {event, metadata})
    end, nil)

    {:ok, pid} = GenServer.start_link(result.module, [])
    GenServer.call(pid, {:ping, %{value: :hello}})

    received = :ets.lookup(events, [:vor, :message, :received])
    assert length(received) >= 1
    {_, metadata} = hd(received)
    assert metadata.message_tag == :ping

    :telemetry.detach("test-received")
    GenServer.stop(pid)
    :ets.delete(events)
  end

  test "agent name from __vor_agent_name__ arg appears in telemetry" do
    source = """
    agent Node do
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
    events = :ets.new(:test_events, [:bag, :public])

    :telemetry.attach("test-agent-name", [:vor, :message, :received], fn event, _m, metadata, _ ->
      :ets.insert(events, {event, metadata})
    end, nil)

    {:ok, pid} = GenServer.start_link(result.module, [__vor_agent_name__: :my_node])
    GenServer.call(pid, {:ping, %{}})

    received = :ets.lookup(events, [:vor, :message, :received])
    {_, metadata} = hd(received)
    assert metadata.agent == :my_node

    :telemetry.detach("test-agent-name")
    GenServer.stop(pid)
    :ets.delete(events)
  end

  test "all existing examples compile with telemetry enabled" do
    for file <- Path.wildcard("examples/*.vor") do
      source = File.read!(file)

      result =
        if String.contains?(source, "system ") do
          Vor.Compiler.compile_system(source)
        else
          Vor.Compiler.compile_string(source)
        end

      assert match?({:ok, _}, result), "Failed: #{file}"
    end
  end
end
