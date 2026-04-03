# bench/system_perf.exs
# System startup and messaging throughput benchmarks
#
# Usage: mix run bench/system_perf.exs

defmodule Bench.SystemPerf do
  @runs 10

  def run do
    IO.puts("=== Vor System Performance Benchmarks ===\n")

    bench_startup()
    bench_two_agent_throughput()
    bench_pipeline_throughput()
    bench_broadcast_throughput()
  end

  # --- System startup with varying agent count ---

  defp bench_startup do
    IO.puts("-- System Startup Time (varying agent count) --")

    for n <- [2, 4, 6, 8, 10] do
      source = gen_system(n)
      {:ok, result} = Vor.Compiler.compile_system_and_load(source)

      measure("startup with #{n} agents", fn ->
        {:ok, sup_pid} = result.system.start_link.()
        Supervisor.stop(sup_pid)
      end)
    end

    IO.puts("")
  end

  # --- Two-agent message throughput ---

  defp bench_two_agent_throughput do
    IO.puts("-- Two-Agent Message Throughput (1000 messages) --")

    source = """
    agent Sender do
      protocol do
        accepts {:ping, n: integer}
        sends {:data, value: integer}
        emits {:ack}
      end

      on {:ping, n: N} do
        send :receiver {:data, value: N}
        emit {:ack}
      end
    end

    agent Receiver do
      state count: integer

      protocol do
        accepts {:data, value: integer}
        accepts {:get_count}
        emits {:count, value: integer}
      end

      on {:data, value: _V} do
        transition count: count + 1
      end

      on {:get_count} do
        emit {:count, value: count}
      end
    end

    system TwoAgent do
      agent :sender, Sender()
      agent :receiver, Receiver()
      connect :sender -> :receiver
    end
    """

    {:ok, result} = Vor.Compiler.compile_system_and_load(source)

    measure("1000 call-and-forward messages", fn ->
      {:ok, sup_pid} = result.system.start_link.()
      registry = result.system.registry

      [{sender_pid, _}] = Registry.lookup(registry, :sender)

      for i <- 1..1000 do
        GenServer.call(sender_pid, {:ping, %{n: i}})
      end

      # Wait for async sends to settle
      Process.sleep(100)

      [{receiver_pid, _}] = Registry.lookup(registry, :receiver)
      {:count, %{value: 1000}} = GenServer.call(receiver_pid, {:get_count, %{}})

      Supervisor.stop(sup_pid)
    end)

    IO.puts("")
  end

  # --- Three-agent pipeline throughput ---

  defp bench_pipeline_throughput do
    IO.puts("-- Three-Agent Pipeline Throughput (1000 messages) --")

    source = """
    agent Source do
      protocol do
        accepts {:produce, n: integer}
        sends {:item, value: integer}
        emits {:ok}
      end

      on {:produce, n: N} do
        send :transformer {:item, value: N}
        emit {:ok}
      end
    end

    agent Transformer do
      protocol do
        accepts {:item, value: integer}
        sends {:result, doubled: integer}
      end

      on {:item, value: V} do
        send :sink {:result, doubled: V + V}
      end
    end

    agent Sink do
      state total: integer

      protocol do
        accepts {:result, doubled: integer}
        accepts {:get_total}
        emits {:total, value: integer}
      end

      on {:result, doubled: D} do
        transition total: total + D
      end

      on {:get_total} do
        emit {:total, value: total}
      end
    end

    system Pipeline do
      agent :source, Source()
      agent :transformer, Transformer()
      agent :sink, Sink()
      connect :source -> :transformer
      connect :transformer -> :sink
    end
    """

    {:ok, result} = Vor.Compiler.compile_system_and_load(source)

    measure("1000 messages through 3-stage pipeline", fn ->
      {:ok, sup_pid} = result.system.start_link.()
      registry = result.system.registry

      [{source_pid, _}] = Registry.lookup(registry, :source)

      for i <- 1..1000 do
        GenServer.call(source_pid, {:produce, %{n: i}})
      end

      # Wait for async pipeline to settle
      Process.sleep(200)

      [{sink_pid, _}] = Registry.lookup(registry, :sink)
      {:total, %{value: _total}} = GenServer.call(sink_pid, {:get_total, %{}})

      Supervisor.stop(sup_pid)
    end)

    IO.puts("")
  end

  # --- Broadcast throughput ---

  defp bench_broadcast_throughput do
    IO.puts("-- Broadcast Throughput (500 broadcasts, varying receivers) --")

    for n <- [2, 4, 6, 8, 10] do
      source = gen_broadcast_system(n)
      {:ok, result} = Vor.Compiler.compile_system_and_load(source)

      measure("500 broadcasts to #{n} receivers", fn ->
        {:ok, sup_pid} = result.system.start_link.()
        registry = result.system.registry

        [{sender_pid, _}] = Registry.lookup(registry, :sender)

        for i <- 1..500 do
          GenServer.call(sender_pid, {:go, %{n: i}})
        end

        # Wait for broadcasts to settle
        Process.sleep(200)

        Supervisor.stop(sup_pid)
      end)
    end

    IO.puts("")
  end

  # --- Generators ---

  defp gen_system(n) do
    agents =
      for i <- 1..n do
        """
        agent Worker#{i} do
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
      |> Enum.join("\n")

    agent_decls =
      for i <- 1..n do
        "  agent :worker_#{i}, Worker#{i}()"
      end
      |> Enum.join("\n")

    """
    #{agents}

    system Startup#{n} do
    #{agent_decls}
    end
    """
  end

  defp gen_broadcast_system(n) do
    receivers =
      for i <- 1..n do
        """
        agent Recv#{i} do
          state count: integer

          protocol do
            accepts {:data, value: integer}
            accepts {:get_count}
            emits {:count, value: integer}
          end

          on {:data, value: _V} do
            transition count: count + 1
          end

          on {:get_count} do
            emit {:count, value: count}
          end
        end
        """
      end
      |> Enum.join("\n")

    agent_decls =
      ["  agent :sender, BcastSender()"] ++
        for i <- 1..n do
          "  agent :recv_#{i}, Recv#{i}()"
        end

    connections =
      for i <- 1..n do
        "  connect :sender -> :recv_#{i}"
      end

    """
    agent BcastSender do
      protocol do
        accepts {:go, n: integer}
        sends {:data, value: integer}
        emits {:ok}
      end

      on {:go, n: N} do
        broadcast {:data, value: N}
        emit {:ok}
      end
    end

    #{receivers}

    system Bcast#{n} do
    #{Enum.join(agent_decls, "\n")}
    #{Enum.join(connections, "\n")}
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

Bench.SystemPerf.run()
