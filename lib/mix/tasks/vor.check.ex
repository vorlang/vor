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
      mix vor.check --integer-bound 5          # cap tracked integer fields
      mix vor.check --max-queue 20             # cap pending message buffer
      mix vor.check --no-symmetry              # disable symmetry reduction

  ## Options

    * `--depth N` — maximum BFS depth (default 50)
    * `--max-states N` — maximum number of distinct product states explored
      before falling back to bounded reporting (default 100,000)
    * `--integer-bound N` — saturation cap applied to tracked integer state
      fields (default 3). Higher values explore more of the integer domain
      but grow the state space.
    * `--max-queue N` — bounded network-buffer cap on pending messages
      (default 10). When delivering a message would push the queue past
      this cap the surplus outgoing messages are silently dropped — a
      lossy-network model. Increase the cap for stronger guarantees at the
      cost of state-space growth.
    * `--no-symmetry` — disable symmetry reduction. By default symmetry is
      auto-detected for homogeneous fully-symmetric systems whose
      invariants do not reference specific named agents.
  """

  alias Vor.Explorer
  alias Vor.Explorer.ProductState

  def run(args) do
    Mix.Task.run("app.start")

    {opts, files, _} =
      OptionParser.parse(args,
        strict: [
          depth: :integer,
          max_states: :integer,
          integer_bound: :integer,
          max_queue: :integer,
          symmetry: :boolean
        ],
        aliases: [d: :depth]
      )

    max_depth = Keyword.get(opts, :depth, 50)
    max_states = Keyword.get(opts, :max_states, 100_000)
    integer_bound = Keyword.get(opts, :integer_bound, 3)
    max_queue = Keyword.get(opts, :max_queue, 10)
    # `--no-symmetry` arrives as `symmetry: false`; default `:auto` lets the
    # explorer detect when reduction is safe.
    symmetry_opt = Keyword.get(opts, :symmetry, :auto)

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

          case Explorer.check_file(source,
                 max_depth: max_depth,
                 max_states: max_states,
                 integer_bound: integer_bound,
                 max_queue: max_queue,
                 symmetry: symmetry_opt
               ) do
            {:ok, :proven, stats} ->
              print_abstraction(stats)

              Mix.shell().info(
                "  ✓ Proven (#{stats.states_explored} states, depth #{stats.max_depth_reached})"
              )

              :ok

            {:ok, :bounded, stats} ->
              print_abstraction(stats)

              Mix.shell().info(
                "  ~ Bounded verification (#{stats.states_explored} states, depth #{stats.max_depth_reached})"
              )

              Mix.shell().info(
                "    Increase --depth, --max-states or --integer-bound for an exhaustive check."
              )

              :ok

            {:ok, :no_invariants, _stats} ->
              Mix.shell().info("  - No system-level invariants to check")
              :ok

            {:error, :violation, name, trace, stats} ->
              print_abstraction(stats)
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

  defp print_abstraction(%{relevance: nil}), do: :ok
  defp print_abstraction(%{relevance: relevance} = stats) when map_size(relevance) > 0 do
    {tracked, abstracted} =
      Enum.reduce(relevance, {MapSet.new(), MapSet.new()}, fn {_name, info}, {t, a} ->
        {MapSet.union(t, info.tracked_state), MapSet.union(a, info.abstracted)}
      end)

    if MapSet.size(tracked) + MapSet.size(abstracted) > 0 do
      tracked_list = tracked |> MapSet.to_list() |> Enum.sort() |> Enum.join(", ")
      abstracted_list = abstracted |> MapSet.to_list() |> Enum.sort() |> Enum.join(", ")

      Mix.shell().info("    Tracked fields:    #{if tracked_list == "", do: "(none)", else: tracked_list}")
      Mix.shell().info("    Abstracted fields: #{if abstracted_list == "", do: "(none)", else: abstracted_list}")
      Mix.shell().info("    Integer bound:     #{Map.get(stats, :integer_bound, "?")}")
      Mix.shell().info("    Max queue:         #{Map.get(stats, :max_queue, "?")}")
      Mix.shell().info("    Symmetry:          #{symmetry_label(stats)}")
    end

    :ok
  end
  defp print_abstraction(_), do: :ok

  defp symmetry_label(%{symmetry: true} = stats) do
    n = stats |> Map.get(:relevance, %{}) |> map_size()

    factor =
      case n do
        0 -> 1
        1 -> 1
        _ -> Enum.reduce(2..n, 1, &(&1 * &2))
      end

    "enabled (#{n} identical agents, #{factor}× reduction)"
  end

  defp symmetry_label(%{symmetry: false}), do: "disabled"
  defp symmetry_label(_), do: "?"

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
