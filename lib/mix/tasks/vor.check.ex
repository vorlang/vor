defmodule Mix.Tasks.Vor.Check do
  use Mix.Task

  @shortdoc "Run Vor multi-agent model checking on .vor system blocks"

  @moduledoc """
  Runs the Vor multi-agent model checker on one or more `.vor` files
  containing `system` blocks with system-level safety invariants.

  Standard `mix compile` only parses system invariants — it never runs the
  product-state exploration, which can be expensive. `mix vor.check`
  performs the BFS exploration and reports per-file results.

  ## Usage

      mix vor.check                            # check all examples/*.vor
      mix vor.check examples/raft_cluster.vor  # check a specific file
      mix vor.check --depth 30                 # custom depth bound
      mix vor.check --max-states 200000        # custom state-count bound

  ## Options

    * `--depth N` — maximum BFS depth (default 50)
    * `--max-states N` — maximum number of distinct product states explored
      before falling back to bounded reporting (default 100,000)
  """

  alias Vor.Explorer
  alias Vor.Explorer.ProductState

  def run(args) do
    Mix.Task.run("app.start")

    {opts, files, _} =
      OptionParser.parse(args,
        strict: [depth: :integer, max_states: :integer],
        aliases: [d: :depth]
      )

    max_depth = Keyword.get(opts, :depth, 50)
    max_states = Keyword.get(opts, :max_states, 100_000)

    files =
      case files do
        [] -> default_files()
        list -> list
      end

    if files == [] do
      Mix.shell().info("No .vor files found.")
    else
      results =
        Enum.map(files, fn file ->
          Mix.shell().info("Checking #{file}...")
          source = File.read!(file)

          case Explorer.check_file(source, max_depth: max_depth, max_states: max_states) do
            {:ok, :proven, stats} ->
              Mix.shell().info(
                "  ✓ Proven (#{stats.states_explored} states, depth #{stats.max_depth_reached})"
              )

              :ok

            {:ok, :bounded, stats} ->
              Mix.shell().info(
                "  ~ Bounded verification (#{stats.states_explored} states, depth #{stats.max_depth_reached})"
              )

              Mix.shell().info("    Increase --depth or --max-states for an exhaustive check.")

              :ok

            {:ok, :no_invariants, _stats} ->
              Mix.shell().info("  - No system-level invariants to check")
              :ok

            {:error, :violation, name, trace, stats} ->
              Mix.shell().error("  ✗ Violation: \"#{name}\"")
              Mix.shell().error(format_counterexample(trace))

              Mix.shell().error(
                "  (#{stats.states_explored} states explored, max depth #{stats.max_depth_reached})"
              )

              {:violation, name, file}

            {:error, reason} ->
              Mix.shell().error("  ✗ Compile error: #{inspect(reason)}")
              {:compile_error, file, reason}
          end
        end)

      failures = Enum.reject(results, &(&1 == :ok))

      case failures do
        [] -> :ok
        [first | _] -> Mix.raise("Vor check failed: #{inspect(first)}")
      end
    end
  end

  defp default_files do
    Path.wildcard("examples/*.vor")
    |> Enum.filter(fn path ->
      File.read!(path) |> String.contains?("system ")
    end)
  end

  # ----------------------------------------------------------------------
  # Counterexample formatting (Milestone 8)
  # ----------------------------------------------------------------------

  @doc false
  def format_counterexample(trace) do
    trace
    |> Enum.with_index()
    |> Enum.map(&format_step/1)
    |> Enum.join("\n\n")
  end

  defp format_step({%ProductState{} = ps, idx}) do
    header = "  Step #{idx}: #{describe_action(ps.last_action)}"
    agent_lines = format_agents(ps.agents)
    pending_line = format_pending(ps.pending_messages)

    [header, agent_lines, pending_line]
    |> Enum.reject(&(&1 == "" or is_nil(&1)))
    |> Enum.join("\n")
  end

  defp describe_action(:initial), do: "Initial state"

  defp describe_action({:deliver, from, to, {tag, _fields}}),
    do: "Deliver #{inspect(tag)} from #{from} to #{to}"

  defp describe_action({:external, agent, {tag, _fields}}),
    do: "External #{inspect(tag)} delivered to #{agent}"

  defp describe_action({:timeout, agent}), do: "Liveness timeout on #{agent}"
  defp describe_action(other), do: inspect(other)

  defp format_agents(agents) do
    agents
    |> Enum.sort_by(fn {name, _} -> name end)
    |> Enum.map(fn {name, state} ->
      pairs =
        state
        |> Enum.sort_by(fn {k, _} -> k end)
        |> Enum.map(fn {k, v} -> "#{k}=#{inspect(v)}" end)
        |> Enum.join(", ")

      "    #{name}: #{pairs}"
    end)
    |> Enum.join("\n")
  end

  defp format_pending([]), do: nil

  defp format_pending(messages) do
    parts =
      Enum.map(messages, fn {from, to, {tag, _}} ->
        "#{from}→#{to}: #{inspect(tag)}"
      end)

    "    pending: [#{Enum.join(parts, ", ")}]"
  end
end
