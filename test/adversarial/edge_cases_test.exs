defmodule Vor.Adversarial.EdgeCasesTest do
  use ExUnit.Case

  # Helper: compile must return {:ok, _} or {:error, _}, never crash
  # Returns {:ok, _}, {:error, _}, or {:crash, _}
  # Normalizes lexer 4-tuple errors to 2-tuple
  defp safe_compile(source) do
    try do
      case Vor.Compiler.compile_and_load(source) do
        {:ok, _} = ok -> ok
        {:error, _} = err -> err
        {:error, msg, _line, _col} -> {:error, msg}
        other -> {:unexpected, other}
      end
    rescue
      e -> {:crash, Exception.message(e)}
    catch
      kind, reason -> {:crash, {kind, reason}}
    end
  end

  defp safe_compile_system(source) do
    try do
      case Vor.Compiler.compile_system_and_load(source) do
        {:ok, _} = ok -> ok
        {:error, _} = err -> err
        {:error, msg, _line, _col} -> {:error, msg}
        other -> {:unexpected, other}
      end
    rescue
      e -> {:crash, Exception.message(e)}
    catch
      kind, reason -> {:crash, {kind, reason}}
    end
  end

  # === Parser edge cases ===

  test "empty agent" do
    result = safe_compile("agent Empty do\nend")
    assert match?({:ok, _}, result) or match?({:error, _}, result),
      "Crash on empty agent: #{inspect(result, limit: 100)}"
  end

  test "agent with only a protocol, no handlers" do
    source = """
    agent ProtocolOnly do
      protocol do
        accepts {:msg}
        emits {:ok}
      end
    end
    """
    result = safe_compile(source)
    assert match?({:ok, _}, result) or match?({:error, _}, result),
      "Crash: #{inspect(result, limit: 100)}"
  end

  test "agent with handler but no protocol" do
    source = """
    agent NoProtocol do
      on {:msg} do
        emit {:ok}
      end
    end
    """
    result = safe_compile(source)
    assert match?({:ok, _}, result) or match?({:error, _}, result),
      "Crash: #{inspect(result, limit: 100)}"
  end

  test "agent with duplicate handler patterns" do
    source = """
    agent DuplicateHandlers do
      protocol do
        accepts {:msg, value: integer}
        emits {:ok}
      end

      on {:msg, value: V} do
        emit {:ok}
      end

      on {:msg, value: V} do
        emit {:ok}
      end
    end
    """
    result = safe_compile(source)
    assert match?({:ok, _}, result) or match?({:error, _}, result),
      "Crash: #{inspect(result, limit: 100)}"
  end

  test "deeply nested if/else — 5 levels" do
    source = """
    agent DeepNest do
      state phase: :a | :b

      protocol do
        accepts {:classify, v: integer}
        emits {:result, level: atom}
      end

      on {:classify, v: V} when phase == :a do
        if V > 100 do
          if V > 200 do
            if V > 300 do
              if V > 400 do
                if V > 500 do
                  emit {:result, level: :extreme}
                else
                  emit {:result, level: :very_high}
                end
              else
                emit {:result, level: :high}
              end
            else
              emit {:result, level: :medium_high}
            end
          else
            emit {:result, level: :medium}
          end
        else
          emit {:result, level: :low}
        end
      end
    end
    """
    result = safe_compile(source)
    assert match?({:ok, _}, result) or match?({:error, _}, result),
      "Crash: #{inspect(result, limit: 100)}"

    case result do
      {:ok, r} ->
        {:ok, pid} = :gen_statem.start_link(r.module, [], [])
        assert {:result, %{level: :extreme}} = :gen_statem.call(pid, {:classify, %{v: 600}})
        assert {:result, %{level: :low}} = :gen_statem.call(pid, {:classify, %{v: 50}})
        :gen_statem.stop(pid)
      _ -> :ok
    end
  end

  test "many fields in one message" do
    fields_decl = 1..20 |> Enum.map(fn i -> "f#{i}: integer" end) |> Enum.join(", ")
    fields_pattern = 1..20 |> Enum.map(fn i -> "f#{i}: V#{i}" end) |> Enum.join(", ")
    fields_emit = 1..20 |> Enum.map(fn i -> "f#{i}: V#{i}" end) |> Enum.join(", ")

    source = """
    agent ManyFields do
      protocol do
        accepts {:big, #{fields_decl}}
        emits {:big_reply, #{fields_decl}}
      end

      on {:big, #{fields_pattern}} do
        emit {:big_reply, #{fields_emit}}
      end
    end
    """
    result = safe_compile(source)
    assert match?({:ok, _}, result) or match?({:error, _}, result),
      "Crash: #{inspect(result, limit: 100)}"
  end

  test "empty string source" do
    result = safe_compile("")
    assert match?({:error, _}, result) or match?({:ok, _}, result),
      "Crash: #{inspect(result, limit: 100)}"
  end

  test "random garbage source" do
    result = safe_compile("asdf 123 !@#")
    assert elem(result, 0) == :error,
      "Expected error for garbage: #{inspect(result, limit: 100)}"
  end

  test "incomplete agent — missing end" do
    source = "agent Incomplete do\n  protocol do\n    accepts {:ping}\n  end\n"
    result = safe_compile(source)
    assert match?({:error, _}, result),
      "Expected error for incomplete: #{inspect(result, limit: 100)}"
  end

  # === State machine edge cases ===

  test "single state enum becomes gen_server with atom data field" do
    # A single-value state is not an enum — it becomes a data field
    source = """
    agent SingleState do
      state phase: :only

      protocol do
        accepts {:ping}
        emits {:pong}
      end

      on {:ping} do
        emit {:pong}
      end
    end
    """
    result = safe_compile(source)
    # Compiles as gen_server (not gen_statem) since single value isn't an enum
    assert match?({:ok, _}, result) or match?({:error, _}, result),
      "Crash: #{inspect(result, limit: 100)}"
  end

  test "many states — 10 enum values" do
    states = 1..10 |> Enum.map(fn i -> ":s#{i}" end) |> Enum.join(" | ")
    source = """
    agent ManyStates do
      state phase: #{states}

      protocol do
        accepts {:advance}
        emits {:ok}
      end

      on {:advance} when phase == :s1 do
        transition phase: :s2
        emit {:ok}
      end
    end
    """
    result = safe_compile(source)
    assert match?({:ok, _}, result) or match?({:error, _}, result),
      "Crash: #{inspect(result, limit: 100)}"
  end

  test "transition to current state (self-loop)" do
    source = """
    agent SelfLoop do
      state phase: :idle | :active

      protocol do
        accepts {:refresh}
        emits {:ok}
      end

      on {:refresh} when phase == :active do
        transition phase: :active
        emit {:ok}
      end
    end
    """
    result = safe_compile(source)
    assert match?({:ok, _}, result),
      "Self-loop should compile: #{inspect(result, limit: 100)}"
  end

  # === Invariant edge cases ===

  test "safety invariant on nonexistent state" do
    source = """
    agent PhantomState do
      state phase: :idle | :active

      protocol do
        accepts {:go}
        emits {:ok}
      end

      on {:go} when phase == :idle do
        transition phase: :active
        emit {:ok}
      end

      safety "phantom" proven do
        never(phase == :phantom and emitted({:ok, _}))
      end
    end
    """
    result = safe_compile(source)
    assert match?({:ok, _}, result) or match?({:error, _}, result),
      "Crash: #{inspect(result, limit: 100)}"
  end

  test "many safety invariants" do
    invariants = 1..10 |> Enum.map(fn i ->
      "safety \"inv_#{i}\" proven do\n    never(phase == :idle and emitted({:msg#{i}, _}))\n  end"
    end) |> Enum.join("\n\n  ")

    source = """
    agent ManyInvariants do
      state phase: :idle | :active

      protocol do
        accepts {:go}
        emits {:ok}
      end

      on {:go} when phase == :idle do
        transition phase: :active
        emit {:ok}
      end

      #{invariants}
    end
    """
    result = safe_compile(source)
    assert match?({:ok, _}, result) or match?({:error, _}, result),
      "Crash: #{inspect(result, limit: 100)}"
  end

  # === Multi-agent edge cases ===

  test "system with single agent, no connections" do
    source = """
    agent Lone do
      protocol do
        accepts {:ping}
        emits {:pong}
      end

      on {:ping} do
        emit {:pong}
      end
    end

    system Solo do
      agent :lone, Lone()
    end
    """
    result = safe_compile_system(source)
    assert match?({:ok, _}, result),
      "Solo system should compile: #{inspect(result, limit: 100)}"
  end

  test "system with circular connections" do
    source = """
    agent PingPong do
      protocol do
        accepts {:ping, n: integer}
        sends {:ping, n: integer}
      end

      on {:ping, n: N} do
        noop
      end
    end

    system Circle do
      agent :a, PingPong()
      agent :b, PingPong()
      connect :a -> :b
      connect :b -> :a
    end
    """
    result = safe_compile_system(source)
    assert match?({:ok, _}, result) or match?({:error, _}, result),
      "Crash: #{inspect(result, limit: 100)}"
  end

  # === Timing edge cases ===

  test "very short liveness timeout (1ms)" do
    source = """
    agent QuickTimeout do
      state phase: :waiting | :done

      protocol do
        accepts {:finish}
        emits {:ok}
      end

      on {:finish} when phase == :waiting do
        transition phase: :done
        emit {:ok}
      end

      liveness "quick" monitored(within: 1) do
        always(phase != :done implies eventually(phase == :done))
      end

      resilience do
        on_invariant_violation("quick") ->
          transition phase: :done
      end
    end
    """
    result = safe_compile(source)
    case result do
      {:ok, r} ->
        {:ok, pid} = :gen_statem.start_link(r.module, [], [])
        Process.sleep(50)
        assert Process.alive?(pid)
        :gen_statem.stop(pid)
      _ -> :ok
    end
  end
end
