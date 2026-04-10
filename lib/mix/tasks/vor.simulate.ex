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
      mix vor.simulate --seed 42                 # reproducible run
      mix vor.simulate --no-faults               # invariant checking only
      mix vor.simulate --verbose                 # print every event

  ## Options

    * `--duration N` — simulation length in milliseconds (default 30000)
    * `--seed N` — random seed for reproducibility (default random)
    * `--kill-min N` — minimum ms between kills (default 3000)
    * `--kill-max N` — maximum ms between kills (default 10000)
    * `--check-interval N` — ms between invariant checks (default 1000)
    * `--no-faults` — run without fault injection (just start + check)
    * `--verbose` — print each event as it happens
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
          faults: :boolean
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
          check_interval_ms: check_interval,
          verbose: verbose,
          inject_faults: inject_faults
        }

        case Vor.Simulator.run_file(file, config) do
          {:ok, :pass, stats} ->
            Mix.shell().info(
              "  ✓ PASS — #{stats.invariant_checks} checks, " <>
                "#{stats.faults_injected} faults, 0 violations"
            )

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
        end
      end)
    end
  end

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
