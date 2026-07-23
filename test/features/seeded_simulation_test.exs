defmodule Vor.Features.SeededSimulationTest do
  @moduledoc """
  Phase 2a — seeded controllable simulation rediscovers the Raft
  leader-uniqueness bug on REAL BEAM processes.

  This is the cross-validation of the model checker: the checker found, analytically,
  that the *global* `never(count(role == :leader) > 1)` invariant is violated by a
  stale leader from an earlier term coexisting with a newer leader. Here we drive
  real Raft processes into the same state via a seeded partition schedule.

  It is **structurally vacuity-proof**: there is no abstract model to be empty —
  real processes either elected two leaders or they didn't, and we read their live
  state. The test is tolerant of the residual (uncontrolled) non-determinism —
  BEAM scheduling and real OTP timers — by trying a few known-good seeds and
  asserting the bug is found within them (each is empirically ~100% reproducible,
  see evidence/phase2a-simulation.md).
  """
  use ExUnit.Case, async: false

  @fixture "test/fixtures/raft_global_sim.vor"
  # Seeds empirically observed to reproduce the two-leader violation (each 15/15
  # in isolation). We try several because reproduction, while ~100% on an idle
  # machine, degrades under heavy concurrent CPU load (the residual scheduler /
  # OTP-timer non-determinism this phase documents) — `Enum.find_value` stops at
  # the first hit, so a healthy run is one ~12s simulation.
  @known_good_seeds [12, 13, 8, 9, 10, 14, 16, 17, 18]

  defp config(seed) do
    %{
      duration_ms: 12_000,
      seed: seed,
      kill_interval: {500, 1200},
      fault_interval: {500, 1200},
      check_interval_ms: 200,
      inject_faults: true,
      enable_partitions: true,
      enable_delays: false,
      partition_duration: {2000, 3500},
      delay_range: 50..200,
      workload_rate: 0,
      verbose: false
    }
  end

  @tag timeout: 300_000
  test "seeded simulation rediscovers the Raft two-leaders-across-terms bug on real processes" do
    {:ok, system_info} = Vor.Simulator.compile_for_simulation(File.read!(@fixture))

    # Try known-good seeds in order; stop at the first that reproduces the
    # violation. (Tolerant of probabilistic reproduction — see moduledoc.)
    found =
      Enum.find_value(@known_good_seeds, fn seed ->
        case Vor.Simulator.run_system(system_info, config(seed)) do
          {:error, :violation, "at most one leader", details, _stats} -> {seed, details}
          _ -> nil
        end
      end)

    assert {_seed, details} = found,
           "seeded simulation did not rediscover the two-leader violation in seeds #{inspect(@known_good_seeds)}"

    # The violation is a real two-leader state read from live process data.
    leader_terms =
      for {_name, s} <- details.agent_states,
          is_map(s),
          Map.get(s, :role) == :leader,
          do: Map.get(s, :current_term)

    assert length(leader_terms) >= 2, "expected ≥2 live leaders, got #{inspect(leader_terms)}"

    # And it is the SAME class the model checker found: leaders in DIFFERENT terms
    # (a legal transient stale leader), never a same-term double-election.
    assert length(Enum.uniq(leader_terms)) >= 2,
           "expected leaders in different terms (stale-leader bug), got #{inspect(leader_terms)}"
  end
end
