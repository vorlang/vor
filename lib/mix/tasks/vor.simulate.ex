defmodule Mix.Tasks.Vor.Simulate do
  use Mix.Task

  @shortdoc "Run chaos simulation on Vor systems"

  @moduledoc """
  Starts real BEAM processes from a Vor system block, periodically kills
  random agents (letting OTP supervisors restart them), and checks that
  declared system-level safety invariants hold throughout.

  ## Usage

      mix vor.simulate                           # defaults (30s, random seed)
      mix vor.simulate examples/raft_cluster.vor # specific file
      mix vor.simulate --duration 60000          # 60-second run
      mix vor.simulate --seed 42                 # reproducible run (seeds the fault schedule + workload)
      mix vor.simulate --partition --seed 12     # enable seeded network partitions
      mix vor.simulate --no-faults               # invariant checking only
      mix vor.simulate --verbose                 # print every event

  ## Options

    * `--duration N` — simulation length in milliseconds (default 30000)
    * `--seed N` — seed for the fault schedule and workload (default random).
      The **inputs** (which fault, target, timing, duration; workload) are
      deterministic in the seed; the BEAM scheduler and real OTP timers are not,
      so replay of a timing-sensitive bug may be probabilistic — see
      `evidence/phase2a-simulation.md`.
    * `--check-interval N` — ms between invariant checks (default 1000). Lower it
      to catch transient violations.
    * `--partition` — enable seeded network partitions (a proxy drops all traffic
      to/from an isolated agent for a bounded duration).
    * `--partition-dur-min N` / `--partition-dur-max N` — partition duration range (ms).
    * `--delay` — enable seeded message-delay faults.
    * `--delay-min N` / `--delay-max N` — per-message delay range (ms).
    * `--fault-interval-min N` / `--fault-interval-max N` — time between faults (ms).
    * `--kill-min N` / `--kill-max N` — legacy kill interval (ms).
    * `--workload N` — inject a client workload at rate N (0 = off).
    * `--no-faults` — run without fault injection (just start + check).
    * `--verbose` — print each event as it happens.
  """

  def run(args) do
    Mix.Task.run("app.start")

    {opts, files, _} =
      OptionParser.parse(args,
        strict: [
          duration: :integer,
          seed: :integer,
          kill_min: :integer,
          kill_max: :integer,
          check_interval: :integer,
          verbose: :boolean,
          faults: :boolean,
          partition: :boolean,
          delay: :boolean,
          delay_min: :integer,
          delay_max: :integer,
          partition_dur_min: :integer,
          partition_dur_max: :integer,
          fault_interval_min: :integer,
          fault_interval_max: :integer,
          workload: :integer
        ]
      )

    duration_ms = Keyword.get(opts, :duration, 30_000)
    seed = Keyword.get(opts, :seed, :rand.uniform(1_000_000))
    kill_min = Keyword.get(opts, :kill_min, 3_000)
    kill_max = Keyword.get(opts, :kill_max, 10_000)
    check_interval = Keyword.get(opts, :check_interval, 1_000)
    verbose = Keyword.get(opts, :verbose, false)
    inject_faults = Keyword.get(opts, :faults, true)

    files =
      case files do
        [] -> discover_system_files()
        given -> given
      end

    if files == [] do
      Mix.shell().info("No system blocks found.")
    else
      Enum.each(files, fn file ->
        Mix.shell().info("Simulating #{file}...")
        Mix.shell().info("  Seed: #{seed} (replay with --seed #{seed})")
        Mix.shell().info("  Duration: #{div(duration_ms, 1000)}s")

        config = %{
          duration_ms: duration_ms,
          seed: seed,
          kill_interval: {kill_min, kill_max},
          fault_interval: {
            Keyword.get(opts, :fault_interval_min, kill_min),
            Keyword.get(opts, :fault_interval_max, kill_max)
          },
          check_interval_ms: check_interval,
          verbose: verbose,
          inject_faults: inject_faults,
          enable_partitions: Keyword.get(opts, :partition, false),
          enable_delays: Keyword.get(opts, :delay, false),
          delay_range: Keyword.get(opts, :delay_min, 50)..Keyword.get(opts, :delay_max, 200),
          partition_duration: {
            Keyword.get(opts, :partition_dur_min, 1000),
            Keyword.get(opts, :partition_dur_max, 5000)
          },
          workload_rate: Keyword.get(opts, :workload, 0)
        }

        case Vor.Simulator.run_file(file, config) do
          {:ok, :pass, stats} ->
            Mix.shell().info(
              "  ✓ PASS — #{stats.invariant_checks} checks, " <>
                "#{stats.faults_injected} faults, 0 violations#{workload_info(stats)}"
            )

            report_axes(stats)

          {:ok, :under_tested, stats} ->
            Mix.shell().info(
              "  ⚠ UNDER-TESTED — no violation, but the run exercised less than it claimed:"
            )

            Enum.each(stats.integrity.reasons, fn r -> Mix.shell().info("      - #{r}") end)

            Mix.shell().info(
              "    #{stats.invariant_checks} checks, #{stats.faults_injected} faults#{workload_info(stats)}"
            )

            report_axes(stats)
            Mix.shell().info("    Replay: mix vor.simulate #{file} --seed #{seed}")

          {:error, :violation, name, details, stats} ->
            Mix.shell().error("  ✗ FAIL — violation: \"#{name}\"")
            Mix.shell().error(format_violation(details))

            Mix.shell().error(
              "  After #{stats.faults_injected} faults, #{stats.invariant_checks} checks"
            )

            Mix.shell().error("  Replay: mix vor.simulate #{file} --seed #{seed}")
            Mix.raise("Simulation failed: invariant \"#{name}\" violated")

          {:error, :system_crash, reason} ->
            Mix.shell().error("  ✗ System crashed: #{inspect(reason)}")
            Mix.raise("Simulation failed: system crash")

          {:error, :dependency_failed, dep, reason} ->
            Mix.shell().error("  ✗ Dependency failed: #{inspect(dep)} — #{inspect(reason)}")
            Mix.raise("Simulation failed: dependency #{inspect(dep)} did not start")
        end
      end)
    end
  end

  defp workload_info(stats) do
    if Map.get(stats, :workload_sent, 0) > 0 do
      ", workload: #{stats.workload_sent} sent/#{stats.workload_ok} ok/#{stats.workload_errors} err/#{stats.workload_timeouts} timeout"
    else
      ""
    end
  end

  # Print the Phase 2b relevance + coverage axes: what a pass actually engaged.
  defp report_axes(stats) do
    report_relevance(Map.get(stats, :relevance, []))
    report_coverage(Map.get(stats, :coverage))
  end

  defp report_relevance([]), do: :ok

  defp report_relevance(relevance) do
    Mix.shell().info("    Invariant relevance:")

    Enum.each(relevance, fn inv ->
      {mark, label} =
        case inv.relevance do
          :substantive -> {"✓", "substantive"}
          :vacuous -> {"⚠", "VACUOUS"}
          :unexercised -> {"·", "unexercised"}
        end

      detail =
        case inv.relevance do
          :vacuous -> "subject `#{inv.subject}` never observed"
          _ -> "subject live in #{inv.subject_live_checks} of #{inv.total_checks} checks"
        end

      Mix.shell().info("      #{mark} \"#{inv.name}\"  #{label}  (#{detail})")
    end)
  end

  defp report_coverage(nil), do: :ok

  defp report_coverage(%{totals: totals}) do
    {rs, ds} = totals.states
    {rh, dh} = totals.handlers
    {re, de} = totals.emits

    Mix.shell().info(
      "    Coverage: reached #{rs}/#{ds} declared states, " <>
        "#{rh}/#{dh} handlers, #{re}/#{de} emitted messages"
    )
  end

  defp report_coverage(_), do: :ok

  defp discover_system_files do
    Path.wildcard("examples/*.vor")
    |> Enum.filter(fn file ->
      File.read!(file) |> String.contains?("system ")
    end)
  end

  defp format_violation(%{agent_states: agent_states, recent_events: recent}) do
    states_str =
      agent_states
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.map(fn {name, state} ->
        if state == :dead do
          "    #{name}: (dead)"
        else
          fields =
            state
            |> Enum.sort_by(fn {k, _} -> k end)
            |> Enum.map(fn {k, v} -> "#{k}=#{inspect(v)}" end)
            |> Enum.join(", ")

          "    #{name}: #{fields}"
        end
      end)
      |> Enum.join("\n")

    recent_str =
      (recent || [])
      |> Enum.map(fn {ts, type, data} ->
        "    #{Float.round(ts / 1000, 1)}s  [#{type}] #{inspect(data)}"
      end)
      |> Enum.join("\n")

    "  Agent states:\n#{states_str}\n\n  Recent events:\n#{recent_str}"
  end

  defp format_violation(_), do: "  (no details)"
end
