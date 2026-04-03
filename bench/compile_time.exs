# bench/compile_time.exs
# Compilation time benchmarks for the Vor compiler
#
# Usage: mix run bench/compile_time.exs

defmodule Bench.CompileTime do
  @runs 10

  def run do
    IO.puts("=== Vor Compilation Time Benchmarks ===\n")

    bench_real_examples()
    bench_varying_handlers()
    bench_varying_states()
    bench_varying_data_fields()
    bench_varying_facts()
    bench_varying_invariants()
  end

  # --- Real-world examples ---

  defp bench_real_examples do
    IO.puts("-- Real Examples --")

    simple = """
    agent Ping do
      state phase: atom = :idle | :active

      on {:ping} do
        transition phase: :active
        emit {:pong}
      end
    end
    """

    medium = """
    agent TrafficLight do
      state phase: atom = :red | :green | :yellow

      protocol do
        accepts {:tick}
        emits {:color, value: atom}
      end

      on {:tick} when phase == :red do
        transition phase: :green
        emit {:color, value: :green}
      end

      on {:tick} when phase == :green do
        transition phase: :yellow
        emit {:color, value: :yellow}
      end

      on {:tick} when phase == :yellow do
        transition phase: :red
        emit {:color, value: :red}
      end

      safety no_skip_yellow: proven do
        never transition from: :red, to: :yellow
      end
    end
    """

    complex = """
    agent OrderProcessor do
      state phase: atom = :new | :validated | :paid | :shipped | :delivered | :cancelled

      protocol do
        accepts {:validate}
        accepts {:pay}
        accepts {:ship}
        accepts {:deliver}
        accepts {:cancel}
        emits {:status, value: atom}
      end

      on {:validate} when phase == :new do
        transition phase: :validated
        emit {:status, value: :validated}
      end

      on {:pay} when phase == :validated do
        transition phase: :paid
        emit {:status, value: :paid}
      end

      on {:ship} when phase == :paid do
        transition phase: :shipped
        emit {:status, value: :shipped}
      end

      on {:deliver} when phase == :shipped do
        transition phase: :delivered
        emit {:status, value: :delivered}
      end

      on {:cancel} when phase == :new do
        transition phase: :cancelled
        emit {:status, value: :cancelled}
      end

      on {:cancel} when phase == :validated do
        transition phase: :cancelled
        emit {:status, value: :cancelled}
      end

      safety no_ship_before_pay: proven do
        never transition from: :new, to: :shipped
      end

      safety no_redeliver: proven do
        never transition from: :delivered, to: :delivered
      end
    end
    """

    measure("simple agent (2 states, 1 handler)", simple)
    measure("medium agent (3 states, 3 handlers)", medium)
    measure("complex agent (6 states, 6 handlers, 2 invariants)", complex)
    IO.puts("")
  end

  # --- Synthetic: varying handler count ---

  defp bench_varying_handlers do
    IO.puts("-- Varying Handler Count --")

    for n <- [2, 5, 10, 20] do
      source = gen_agent_with_handlers(n)
      measure("#{n} handlers", source)
    end

    IO.puts("")
  end

  defp gen_agent_with_handlers(n) do
    handlers =
      for i <- 1..n do
        """
          on {:msg_#{i}} do
            emit {:ack_#{i}}
          end
        """
      end
      |> Enum.join("\n")

    accepts =
      for i <- 1..n do
        "    accepts {:msg_#{i}}"
      end
      |> Enum.join("\n")

    emits =
      for i <- 1..n do
        "    emits {:ack_#{i}}"
      end
      |> Enum.join("\n")

    """
    agent BenchHandlers#{n} do
      protocol do
    #{accepts}
    #{emits}
      end

    #{handlers}
    end
    """
  end

  # --- Synthetic: varying state count ---

  defp bench_varying_states do
    IO.puts("-- Varying State Count --")

    for n <- [3, 5, 10, 20] do
      source = gen_agent_with_states(n)
      measure("#{n} states", source)
    end

    IO.puts("")
  end

  defp gen_agent_with_states(n) do
    state_names = for i <- 1..n, do: ":s#{i}"
    state_decl = Enum.join(state_names, " | ")

    handlers =
      for i <- 1..n do
        next = if i == n, do: 1, else: i + 1

        """
          on {:step} when phase == :s#{i} do
            transition phase: :s#{next}
            emit {:moved, to: :s#{next}}
          end
        """
      end
      |> Enum.join("\n")

    """
    agent BenchStates#{n} do
      state phase: atom = #{state_decl}

      protocol do
        accepts {:step}
        emits {:moved, to: atom}
      end

    #{handlers}
    end
    """
  end

  # --- Synthetic: varying data fields ---

  defp bench_varying_data_fields do
    IO.puts("-- Varying Data Field Count --")

    for n <- [1, 3, 5, 10] do
      source = gen_agent_with_data_fields(n)
      measure("#{n} data fields", source)
    end

    IO.puts("")
  end

  defp gen_agent_with_data_fields(n) do
    fields =
      for i <- 1..n do
        "  data field_#{i}: integer"
      end
      |> Enum.join("\n")

    handler_body =
      for i <- 1..n do
        "    transition field_#{i}: #{i}"
      end
      |> Enum.join("\n")

    """
    agent BenchData#{n} do
    #{fields}

      protocol do
        accepts {:set}
        emits {:ok}
      end

      on {:set} do
    #{handler_body}
        emit {:ok}
      end
    end
    """
  end

  # --- Synthetic: varying fact count ---

  defp bench_varying_facts do
    IO.puts("-- Varying Fact Count --")

    for n <- [1, 3, 5, 10] do
      source = gen_agent_with_facts(n)
      measure("#{n} facts", source)
    end

    IO.puts("")
  end

  defp gen_agent_with_facts(n) do
    facts =
      for i <- 1..n do
        "  fact max_#{i}: 100"
      end
      |> Enum.join("\n")

    """
    agent BenchFacts#{n} do
    #{facts}

      protocol do
        accepts {:ping}
        emits {:pong}
      end

      on {:ping} do
        emit {:pong}
      end
    end
    """
  end

  # --- Synthetic: varying invariant count ---

  defp bench_varying_invariants do
    IO.puts("-- Varying Invariant Count --")

    for n <- [1, 2, 5, 10] do
      source = gen_agent_with_invariants(n)
      measure("#{n} invariants", source)
    end

    IO.puts("")
  end

  defp gen_agent_with_invariants(n) do
    # Need at least n+2 states to generate n distinct "never transition" invariants
    state_count = max(n + 2, 4)
    state_names = for i <- 1..state_count, do: ":s#{i}"
    state_decl = Enum.join(state_names, " | ")

    handlers =
      for i <- 1..state_count do
        next = if i == state_count, do: 1, else: i + 1

        """
          on {:step} when phase == :s#{i} do
            transition phase: :s#{next}
          end
        """
      end
      |> Enum.join("\n")

    # Generate invariants that assert no backward skip (s_i -> s_{i+2})
    invariants =
      for i <- 1..n do
        target = rem(i + 1, state_count) + 1

        """
          safety no_skip_#{i}: proven do
            never transition from: :s#{i}, to: :s#{target}
          end
        """
      end
      |> Enum.join("\n")

    """
    agent BenchInvariants#{n} do
      state phase: atom = #{state_decl}

      protocol do
        accepts {:step}
      end

    #{handlers}
    #{invariants}
    end
    """
  end

  # --- Helpers ---

  defp measure(label, source) do
    times =
      for _ <- 1..@runs do
        {us, _result} = :timer.tc(fn -> Vor.Compiler.compile_string(source) end)
        us
      end

    avg = Enum.sum(times) / @runs
    min = Enum.min(times)
    max = Enum.max(times)

    IO.puts(
      "  #{String.pad_trailing(label, 48)} " <>
        "avg=#{format_time(avg)}  min=#{format_time(min)}  max=#{format_time(max)}"
    )
  end

  defp format_time(us) when us < 1_000, do: "#{Float.round(us / 1, 1)} µs" |> String.pad_leading(10)
  defp format_time(us) when us < 1_000_000, do: "#{Float.round(us / 1_000, 2)} ms" |> String.pad_leading(10)
  defp format_time(us), do: "#{Float.round(us / 1_000_000, 3)} s" |> String.pad_leading(10)
end

Bench.CompileTime.run()
