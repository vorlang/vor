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

  test "transition emits telemetry with from/to values" do
    source = """
    agent Counter do
      state count: integer

      protocol do
        accepts {:inc}
        emits {:ok}
      end

      on {:inc} do
        transition count: count + 1
        emit {:ok}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    events = :ets.new(:test_events, [:bag, :public])

    :telemetry.attach("test-transition", [:vor, :transition], fn _event, _m, metadata, _ ->
      :ets.insert(events, {:transition, metadata})
    end, nil)

    {:ok, pid} = GenServer.start_link(result.module, [])
    GenServer.call(pid, {:inc, %{}})
    GenServer.call(pid, {:inc, %{}})

    transitions = :ets.lookup(events, :transition)
    assert length(transitions) >= 2

    values = Enum.map(transitions, fn {:transition, m} -> {m.from, m.to} end)
    assert {0, 1} in values
    assert {1, 2} in values

    :telemetry.detach("test-transition")
    GenServer.stop(pid)
    :ets.delete(events)
  end

  test "sensitive field redacted in transition telemetry" do
    source = """
    agent Secure do
      state token: binary sensitive
      state count: integer

      protocol do
        accepts {:update, token: binary, count: integer}
        emits {:ok}
      end

      on {:update, token: T, count: C} do
        transition token: T
        transition count: C
        emit {:ok}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    events = :ets.new(:test_events, [:bag, :public])

    :telemetry.attach("test-sensitive", [:vor, :transition], fn _event, _m, metadata, _ ->
      :ets.insert(events, {:transition, metadata})
    end, nil)

    {:ok, pid} = GenServer.start_link(result.module, [])
    GenServer.call(pid, {:update, %{token: "secret123", count: 42}})

    transitions = :ets.lookup(events, :transition)

    token_tr = Enum.find(transitions, fn {:transition, m} -> m.field == :token end)
    assert token_tr
    {:transition, meta} = token_tr
    assert meta.from == :redacted
    assert meta.to == :redacted

    count_tr = Enum.find(transitions, fn {:transition, m} -> m.field == :count end)
    assert count_tr
    {:transition, meta} = count_tr
    assert meta.from == 0
    assert meta.to == 42

    :telemetry.detach("test-sensitive")
    GenServer.stop(pid)
    :ets.delete(events)
  end

  test "gen_statem enum transition emits telemetry with from/to" do
    source = """
    agent Lock do
      state phase: :free | :held

      protocol do
        accepts {:acquire}
        emits {:granted}
      end

      on {:acquire} when phase == :free do
        transition phase: :held
        emit {:granted}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    events = :ets.new(:test_events, [:bag, :public])

    :telemetry.attach("test-enum-tr", [:vor, :transition], fn _event, _m, metadata, _ ->
      :ets.insert(events, {:transition, metadata})
    end, nil)

    {:ok, pid} = :gen_statem.start_link(result.module, [], [])
    :gen_statem.call(pid, {:acquire, %{}})

    transitions = :ets.lookup(events, :transition)
    phase_t = Enum.find(transitions, fn {:transition, m} -> m.field == :phase end)
    assert phase_t
    {:transition, meta} = phase_t
    assert meta.from == :free
    assert meta.to == :held

    :telemetry.detach("test-enum-tr")
    :gen_statem.stop(pid)
    :ets.delete(events)
  end

  test "gen_statem received telemetry includes state atom" do
    source = """
    agent Lock do
      state phase: :free | :held

      protocol do
        accepts {:acquire}
        emits {:granted}
      end

      on {:acquire} when phase == :free do
        transition phase: :held
        emit {:granted}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    events = :ets.new(:test_events, [:bag, :public])

    :telemetry.attach("test-statem-recv", [:vor, :message, :received], fn _event, _m, metadata, _ ->
      :ets.insert(events, {:received, metadata})
    end, nil)

    {:ok, pid} = :gen_statem.start_link(result.module, [], [])
    :gen_statem.call(pid, {:acquire, %{}})

    received = :ets.lookup(events, :received)
    assert length(received) >= 1
    {:received, meta} = hd(received)
    assert meta.message_tag == :acquire
    assert meta.state == :free

    :telemetry.detach("test-statem-recv")
    :gen_statem.stop(pid)
    :ets.delete(events)
  end

  test "gen_statem emit fires telemetry" do
    source = """
    agent Lock do
      state phase: :free | :held

      protocol do
        accepts {:acquire}
        emits {:granted}
      end

      on {:acquire} when phase == :free do
        transition phase: :held
        emit {:granted}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    events = :ets.new(:test_events, [:bag, :public])

    :telemetry.attach("test-statem-emit", [:vor, :message, :emitted], fn _event, _m, metadata, _ ->
      :ets.insert(events, {:emitted, metadata})
    end, nil)

    {:ok, pid} = :gen_statem.start_link(result.module, [], [])
    :gen_statem.call(pid, {:acquire, %{}})

    emitted = :ets.lookup(events, :emitted)
    assert length(emitted) >= 1
    {:emitted, meta} = hd(emitted)
    assert meta.message_tag == :granted

    :telemetry.detach("test-statem-emit")
    :gen_statem.stop(pid)
    :ets.delete(events)
  end

  test "gen_statem full lifecycle: start + received + transition + emitted" do
    source = """
    agent Lock do
      state phase: :free | :held
      state holder: atom

      protocol do
        accepts {:acquire, client: atom}
        emits {:granted, client: atom}
      end

      on {:acquire, client: C} when phase == :free do
        transition phase: :held
        transition holder: C
        emit {:granted, client: C}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    events = :ets.new(:test_events, [:bag, :public])

    handler = fn event, _, _m, _ -> :ets.insert(events, {event, :fired}) end
    :telemetry.attach_many("test-statem-lifecycle", [
      [:vor, :agent, :start],
      [:vor, :message, :received],
      [:vor, :transition],
      [:vor, :message, :emitted]
    ], handler, nil)

    {:ok, pid} = :gen_statem.start_link(result.module, [], [])
    :gen_statem.call(pid, {:acquire, %{client: :alice}})

    all = :ets.tab2list(events)
    event_types = Enum.map(all, fn {event, _} -> event end)

    assert [:vor, :agent, :start] in event_types
    assert [:vor, :message, :received] in event_types
    assert [:vor, :transition] in event_types
    assert [:vor, :message, :emitted] in event_types

    :telemetry.detach("test-statem-lifecycle")
    :gen_statem.stop(pid)
    :ets.delete(events)
  end

  test "lock example emits all telemetry events" do
    source = File.read!("examples/lock.vor")
    {:ok, result} = Vor.Compiler.compile_and_load(source)
    events = :ets.new(:test_events, [:bag, :public])

    handler = fn event, _, _m, _ -> :ets.insert(events, {event, :fired}) end
    :telemetry.attach_many("test-lock", [
      [:vor, :agent, :start],
      [:vor, :message, :received],
      [:vor, :transition],
      [:vor, :message, :emitted]
    ], handler, nil)

    {:ok, pid} = :gen_statem.start_link(result.module, [lock_timeout_ms: 5000], [])
    :gen_statem.call(pid, {:acquire, %{client: :alice}})

    all = :ets.tab2list(events)
    event_types = Enum.map(all, fn {event, _} -> event end)

    assert [:vor, :agent, :start] in event_types
    assert [:vor, :message, :received] in event_types
    assert [:vor, :transition] in event_types
    assert [:vor, :message, :emitted] in event_types

    :telemetry.detach("test-lock")
    :gen_statem.stop(pid)
    :ets.delete(events)
  end

  test "emit fires telemetry with message tag" do
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

    :telemetry.attach("test-emit", [:vor, :message, :emitted], fn _event, _m, metadata, _ ->
      :ets.insert(events, {:emitted, metadata})
    end, nil)

    {:ok, pid} = GenServer.start_link(result.module, [])
    GenServer.call(pid, {:ping, %{value: :hello}})

    emitted = :ets.lookup(events, :emitted)
    assert length(emitted) >= 1
    {:emitted, meta} = hd(emitted)
    assert meta.message_tag == :pong
    assert meta.agent != nil

    :telemetry.detach("test-emit")
    GenServer.stop(pid)
    :ets.delete(events)
  end

  test "full handler lifecycle emits all telemetry events" do
    source = """
    agent FullTelemetry do
      state count: integer

      protocol do
        accepts {:process, value: integer}
        emits {:done, total: integer}
      end

      on {:process, value: V} do
        transition count: count + V
        emit {:done, total: count}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    events = :ets.new(:test_events, [:bag, :public])

    handler = fn event, _m, _metadata, _ ->
      :ets.insert(events, {event, :fired})
    end

    :telemetry.attach_many("test-all", [
      [:vor, :agent, :start],
      [:vor, :message, :received],
      [:vor, :transition],
      [:vor, :message, :emitted]
    ], handler, nil)

    {:ok, pid} = GenServer.start_link(result.module, [])
    GenServer.call(pid, {:process, %{value: 5}})

    all = :ets.tab2list(events)
    event_types = Enum.map(all, fn {event, _} -> event end)

    assert [:vor, :agent, :start] in event_types
    assert [:vor, :message, :received] in event_types
    assert [:vor, :transition] in event_types
    assert [:vor, :message, :emitted] in event_types

    :telemetry.detach("test-all")
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
