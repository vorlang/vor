defmodule Mix.Tasks.Vor.Check do
  use Mix.Task

  @shortdoc "Multi-agent bug-finder / bounded model checker for .vor system blocks"

  @moduledoc """
  Runs the Vor multi-agent model checker on `.vor` files with `system` blocks.

  **This is a bug-finder, not a compile-time verifier.** Multi-agent bounded
  model checking is *not* free during `mix compile` — the honest state space
  explodes with message-queue size (see `KNOWN_ISSUES.md` §4). `mix compile`
  never runs it. This task does, and its headline capability is **fast
  counterexample discovery**; **exhaustive verification at small bounds** is an
  opt-in extra (`--deep`). A `✓` here means "no counterexample within the
  configured bounds", never an unconditional proof.

  ## Usage

      mix vor.check                            # fast smoke check (small default bounds)
      mix vor.check examples/raft_cluster.vor  # smoke-check a specific file
      mix vor.check --deep                     # bounded exhaustive verification (wider bounds)
      mix vor.check --max-queue 6              # widen the message-buffer bound
      mix vor.check --no-symmetry              # disable symmetry reduction
      mix vor.check --no-por                   # disable partial-order reduction
      mix vor.check --no-fire-timers           # old blind mode (ignore timers)

  ## Options

    * `--deep` — bounded *exhaustive* verification. Raises the default bounds
      (queue 4, integer-bound 3, depth 50, max-states 200k). Without it, the
      task runs a **fast smoke check** at small bounds (queue 2, integer-bound
      2, depth 20, max-states 40k) — good for finding bugs quickly, not a
      verification. Explicit `--max-queue` etc. override either way.
    * `--depth N` — maximum BFS depth.
    * `--max-states N` — cap on distinct product states before truncating.
    * `--integer-bound N` — saturation cap applied to tracked integer state
      fields. Higher values explore more of the integer domain but grow the
      state space.
    * `--max-queue N` — bounded network-buffer cap on pending messages. When
      delivering a message would push the queue past this cap the surplus
      outgoing messages are dropped — a lossy-network model. Increasing it
      explores more interleavings at the cost of state-space growth.
    * `--no-por` — disable partial-order reduction (on by default; it explores
      one representative interleaving per independent-event equivalence class).
    * `--no-symmetry` — disable symmetry reduction. By default symmetry is
      auto-detected for homogeneous fully-symmetric systems whose
      invariants do not reference specific named agents.
    * `--no-fire-timers` — do not fire timer/timeout/resilience transitions.
      By default they fire as nondeterministic successors (the honest model);
      this flag restores the old blind mode in which timer-gated behavior is
      never explored (and results about it are vacuous).
    * `--allow-vacuous` — downgrade a vacuous `proven` result from a hard error
      to a warning (for deliberately exploring a partial model).
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
          symmetry: :boolean,
          allow_vacuous: :boolean,
          fire_timers: :boolean,
          por: :boolean,
          deep: :boolean
        ],
        aliases: [d: :depth]
      )

    # Multi-agent model checking is a bug-finder that can *also* do bounded
    # exhaustive verification at small configs — it is NOT compile-time
    # verification (the honest state space explodes; see KNOWN_ISSUES.md §4).
    # So the default is a fast smoke check at small bounds; `--deep` opts into
    # the wider bounds for bounded verification. Explicit flags override either.
    deep = Keyword.get(opts, :deep, false)

    max_depth = Keyword.get(opts, :depth, if(deep, do: 50, else: 20))
    max_states = Keyword.get(opts, :max_states, if(deep, do: 200_000, else: 40_000))
    integer_bound = Keyword.get(opts, :integer_bound, if(deep, do: 3, else: 2))
    max_queue = Keyword.get(opts, :max_queue, if(deep, do: 4, else: 2))
    # `--no-symmetry` arrives as `symmetry: false`; default `:auto` lets the
    # explorer detect when reduction is safe.
    symmetry_opt = Keyword.get(opts, :symmetry, :auto)
    allow_vacuous = Keyword.get(opts, :allow_vacuous, false)
    fire_timers = Keyword.get(opts, :fire_timers, true)
    por = Keyword.get(opts, :por, true)

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
                 symmetry: symmetry_opt,
                 allow_vacuous: allow_vacuous,
                 fire_timers: fire_timers,
                 por: por
               ) do
            {:ok, :proven, stats} ->
              print_abstraction(stats)
              print_relevance(stats)
              print_coverage(stats)

              bounds = "queue #{max_queue}, int-bound #{integer_bound}, depth #{stats.max_depth_reached}"

              if deep do
                Mix.shell().info(
                  "  ✓ No counterexample — exhaustive within bounds (#{stats.states_explored} states; #{bounds})."
                )

                Mix.shell().info(
                  "    Bounded verification, not an unconditional proof: it holds for all reachable states within these bounds."
                )
              else
                Mix.shell().info(
                  "  ✓ No counterexample in the smoke check (#{stats.states_explored} states; #{bounds})."
                )

                Mix.shell().info(
                  "    This is a fast bug-find, NOT verification. Run `--deep` (or widen --max-queue/--integer-bound) for bounded exhaustive checking."
                )
              end

              :ok

            {:ok, :bounded, stats} ->
              print_abstraction(stats)
              print_relevance(stats)
              print_coverage(stats)

              Mix.shell().info(
                "  ~ Truncated — hit a limit at #{stats.states_explored} states (NOT exhaustive; the honest state space is larger than the bound)."
              )

              Mix.shell().info(
                "    No counterexample found in the part explored — this is neither a proof nor a clean bug-find. Reduce the model or raise --max-states/--max-queue."
              )

              :ok

            {:ok, :no_invariants, _stats} ->
              Mix.shell().info("  - No system-level invariants to check")
              :ok

            {:error, :vacuous_proven, names, stats} ->
              print_abstraction(stats)
              print_relevance(stats)
              print_coverage(stats)

              Enum.each(names, fn name ->
                Mix.shell().error("""
                  ✗ VACUOUS PROOF: safety "#{name}" is declared `proven`, but its \
                subject was never reachable in the explored state space.
                    A proof over a state space where the property's subject cannot \
                arise is vacuous. Either the model is incomplete (see \
                KNOWN_ISSUES.md §1), or the invariant does not constrain reachable \
                behavior.
                    Declare it `checked` to accept a weaker guarantee, fix the model \
                so the subject is reachable, or pass --allow-vacuous to override.\
                """)
              end)

              {:vacuous, hd(names), file}

            {:error, :violation, name, trace, stats} ->
              print_abstraction(stats)
              Mix.shell().error("  ✗ Counterexample found — safety \"#{name}\" is violated:")
              Mix.shell().error(format_counterexample(trace))

              Mix.shell().error(
                "  (found after #{stats.states_explored} states, max depth #{stats.max_depth_reached})"
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

  # ----------------------------------------------------------------------
  # Relevance axis (Phase 1): every invariant reports strength AND relevance.
  # A vacuous pass must not look like a real pass.
  # ----------------------------------------------------------------------

  defp print_relevance(%{vacuity: verdicts}) when is_list(verdicts) and verdicts != [] do
    Mix.shell().info("    Invariant relevance:")

    Enum.each(verdicts, fn v ->
      line =
        case v.relevance do
          :substantive ->
            "      ✓ #{v.name}: substantive (subject `#{v.subject}` held in " <>
              "#{v.subject_true_count}/#{v.total_states} states)"

          :vacuous ->
            "      ⚠ #{v.name}: VACUOUS — subject (#{v.subject}) never true in any " <>
              "of the #{v.total_states} explored states"

          :unexercised ->
            "      ⚠ #{v.name}: UNEXERCISED — subject (#{v.subject}) never occurred " <>
              "(monitored behavior not reached)"
        end

      case v.relevance do
        :substantive -> Mix.shell().info(line)
        _ -> Mix.shell().error(line)
      end
    end)

    :ok
  end

  defp print_relevance(_), do: :ok

  # ----------------------------------------------------------------------
  # Declared-vs-reached coverage warnings.
  # ----------------------------------------------------------------------

  defp print_coverage(%{coverage: cov}) when is_map(cov) do
    Enum.each(cov.unreached_states, fn u ->
      Mix.shell().error(
        "    ⚠ agent #{u.agent_type} declares `#{u.field}` values #{inspect(u.declared)} " <>
          "but only #{inspect(u.reached)} was reached. Unreached: #{inspect(u.unreached)}"
      )
    end)

    Enum.each(cov.unfired_handlers, fn h ->
      Mix.shell().error(
        "    ⚠ handler `#{h.label}` (#{h.agent_type}) was never entered during verification"
      )
    end)

    Enum.each(cov.unfired_resilience, fn r ->
      Mix.shell().error(
        "    ⚠ #{r.kind} handler for \"#{r.name}\" (#{r.agent_type}) was never fired. " <>
          "NOTE: the explorer does not fire timer/timeout-triggered transitions (KNOWN_ISSUES.md §1)"
      )
    end)

    Enum.each(cov.unfired_timers, fn t ->
      Mix.shell().error(
        "    ⚠ periodic timer `#{t.tag}` (#{t.agent_type}) never fired. " <>
          "NOTE: the explorer does not fire `every` timers (KNOWN_ISSUES.md §1)"
      )
    end)

    :ok
  end

  defp print_coverage(_), do: :ok

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
