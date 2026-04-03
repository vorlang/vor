# bench/verify_time.exs
# Verification time benchmarks for graph extraction and safety checking
#
# Usage: mix run bench/verify_time.exs

defmodule Bench.VerifyTime do
  @runs 10

  def run do
    IO.puts("=== Vor Verification Time Benchmarks ===\n")

    bench_graph_extraction()
    bench_safety_verification()
    bench_graph_topologies()
  end

  # --- Graph extraction with varying state counts ---

  defp bench_graph_extraction do
    IO.puts("-- Graph Extraction (varying state count) --")

    for n <- [3, 5, 10, 20, 50] do
      source = gen_chain_agent(n)
      measure("extract graph, #{n} states", fn -> Vor.Compiler.extract_graph(source) end)
    end

    IO.puts("")
  end

  # --- Safety verification with varying invariant counts ---

  defp bench_safety_verification do
    IO.puts("-- Full Compile with Safety Verification (varying invariants) --")

    for n <- [1, 3, 5, 10, 20] do
      source = gen_agent_with_invariants(n)
      measure("compile + verify, #{n} invariants", fn -> Vor.Compiler.compile_string(source) end)
    end

    IO.puts("")
  end

  # --- Graph topologies ---

  defp bench_graph_topologies do
    IO.puts("-- Graph Topologies (10 states) --")

    chain = gen_chain_agent(10)
    star = gen_star_agent(10)
    full = gen_full_agent(10)

    measure("chain topology (10 states)", fn -> Vor.Compiler.compile_string(chain) end)
    measure("star topology (10 states)", fn -> Vor.Compiler.compile_string(star) end)
    measure("full topology (10 states)", fn -> Vor.Compiler.compile_string(full) end)

    IO.puts("")

    IO.puts("-- Graph Topologies (20 states) --")

    chain20 = gen_chain_agent(20)
    star20 = gen_star_agent(20)
    full20 = gen_full_agent(20)

    measure("chain topology (20 states)", fn -> Vor.Compiler.compile_string(chain20) end)
    measure("star topology (20 states)", fn -> Vor.Compiler.compile_string(star20) end)
    measure("full topology (20 states)", fn -> Vor.Compiler.compile_string(full20) end)

    IO.puts("")
  end

  # --- Generators ---

  # Chain: s1 -> s2 -> s3 -> ... -> sN -> s1
  defp gen_chain_agent(n) do
    state_names = for i <- 1..n, do: ":s#{i}"
    state_decl = Enum.join(state_names, " | ")

    handlers =
      for i <- 1..n do
        next = if i == n, do: 1, else: i + 1

        """
          on {:step} when phase == :s#{i} do
            transition phase: :s#{next}
          end
        """
      end
      |> Enum.join("\n")

    """
    agent Chain#{n} do
      state phase: atom = #{state_decl}

      protocol do
        accepts {:step}
      end

    #{handlers}
    end
    """
  end

  # Star: hub state s1 connects to all others, each connects back to s1
  defp gen_star_agent(n) do
    state_names = for i <- 1..n, do: ":s#{i}"
    state_decl = Enum.join(state_names, " | ")

    # Hub -> each spoke
    hub_handlers =
      for i <- 2..n do
        """
          on {:go_#{i}} when phase == :s1 do
            transition phase: :s#{i}
          end
        """
      end
      |> Enum.join("\n")

    # Each spoke -> hub
    spoke_handlers =
      for i <- 2..n do
        """
          on {:back} when phase == :s#{i} do
            transition phase: :s1
          end
        """
      end
      |> Enum.join("\n")

    accepts =
      (for i <- 2..n, do: "    accepts {:go_#{i}}") ++ ["    accepts {:back}"]
      |> Enum.join("\n")

    """
    agent Star#{n} do
      state phase: atom = #{state_decl}

      protocol do
    #{accepts}
      end

    #{hub_handlers}
    #{spoke_handlers}
    end
    """
  end

  # Full: every state can transition to every other state
  defp gen_full_agent(n) do
    state_names = for i <- 1..n, do: ":s#{i}"
    state_decl = Enum.join(state_names, " | ")

    handlers =
      for i <- 1..n, j <- 1..n, i != j do
        """
          on {:go_#{j}} when phase == :s#{i} do
            transition phase: :s#{j}
          end
        """
      end
      |> Enum.join("\n")

    accepts =
      for j <- 1..n do
        "    accepts {:go_#{j}}"
      end
      |> Enum.join("\n")

    """
    agent Full#{n} do
      state phase: atom = #{state_decl}

      protocol do
    #{accepts}
      end

    #{handlers}
    end
    """
  end

  defp gen_agent_with_invariants(n) do
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
    agent VerifyInv#{n} do
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

  defp measure(label, fun) do
    times =
      for _ <- 1..@runs do
        {us, _result} = :timer.tc(fun)
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

Bench.VerifyTime.run()
