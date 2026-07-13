defmodule Vor.Features.VacuityTest do
  @moduledoc """
  Phase 1 — vacuity detection as a first-class feature.

  Every invariant reports two axes: strength (proven/checked/monitored) and
  relevance (substantive/vacuous/unexercised). A `proven` invariant that is
  vacuous over an exhaustively-explored space is a hard error (fail-closed),
  with `--allow-vacuous` as the escape hatch.
  """
  use ExUnit.Case, async: true

  alias Vor.Explorer

  # A toggle whose `:on` phase IS reachable via a message.
  defp substantive_source(tier) do
    """
    agent Toggle do
      state phase: :off | :on
      protocol do
        accepts {:flip}
        emits {:ok}
      end
      on {:flip} when phase == :off do
        transition phase: :on
        emit {:ok}
      end
    end

    system S do
      agent :a, Toggle()
      safety "never many on" #{tier} do
        never(count(agents where phase == :on) > 5)
      end
    end
    """
  end

  # `:dead` is declared but has NO transition into it — structurally
  # unreachable, so any invariant about it is vacuous. `:dead_only` is a handler
  # whose guard can never be satisfied.
  defp vacuous_source(tier) do
    """
    agent Corpse do
      state phase: :alive | :dead
      protocol do
        accepts {:noop}
        emits {:ok}
      end
      on {:noop} do
        emit {:ok}
      end
      on {:noop} when phase == :dead do
        emit {:ok}
      end
    end

    system S do
      agent :a, Corpse()
      safety "never dead" #{tier} do
        never(count(agents where phase == :dead) > 0)
      end
    end
    """
  end

  # ----------------------------------------------------------------------
  # Positive: subject reachable → substantive
  # ----------------------------------------------------------------------

  test "an invariant whose subject is reachable is substantive" do
    assert {:ok, :proven, stats} =
             Explorer.check_file(substantive_source("proven"), max_depth: 10, max_states: 1_000)

    assert [verdict] = stats.vacuity
    assert verdict.relevance == :substantive
    assert verdict.subject == "phase == :on"
    assert verdict.subject_true_count > 0
  end

  # ----------------------------------------------------------------------
  # Negative: subject unreachable → vacuous
  # ----------------------------------------------------------------------

  test "an invariant whose subject is unreachable is vacuous (checked tier warns, not errors)" do
    assert {:ok, :proven, stats} =
             Explorer.check_file(vacuous_source("checked"), max_depth: 10, max_states: 1_000)

    assert [verdict] = stats.vacuity
    assert verdict.relevance == :vacuous
    assert verdict.subject == "phase == :dead"
    assert verdict.subject_true_count == 0
  end

  # ----------------------------------------------------------------------
  # Fail-closed: proven + vacuous → error
  # ----------------------------------------------------------------------

  test "a `proven` invariant that is vacuous is a hard error" do
    assert {:error, :vacuous_proven, names, _stats} =
             Explorer.check_file(vacuous_source("proven"), max_depth: 10, max_states: 1_000)

    assert names == ["never dead"]
  end

  test "--allow-vacuous downgrades the fail-closed error to an ok result" do
    assert {:ok, :proven, stats} =
             Explorer.check_file(vacuous_source("proven"),
               max_depth: 10,
               max_states: 1_000,
               allow_vacuous: true
             )

    assert [%{relevance: :vacuous}] = stats.vacuity
  end

  test "a `monitored` invariant whose subject never occurs is unexercised, not an error" do
    assert {:ok, :proven, stats} =
             Explorer.check_file(vacuous_source("monitored"), max_depth: 10, max_states: 1_000)

    assert [%{relevance: :unexercised}] = stats.vacuity
  end

  # ----------------------------------------------------------------------
  # Coverage: declared-but-unreached
  # ----------------------------------------------------------------------

  test "coverage reports unreached enum state values" do
    {:ok, :proven, stats} =
      Explorer.check_file(vacuous_source("checked"), max_depth: 10, max_states: 1_000)

    assert [u] = stats.coverage.unreached_states
    assert u.field == :phase
    assert :dead in u.unreached
    assert :alive in u.reached
  end

  test "coverage reports handlers that were never entered" do
    {:ok, :proven, stats} =
      Explorer.check_file(vacuous_source("checked"), max_depth: 10, max_states: 1_000)

    labels = Enum.map(stats.coverage.unfired_handlers, & &1.label)
    assert Enum.any?(labels, &(&1 =~ "phase == :dead"))
  end

  # ----------------------------------------------------------------------
  # THE REGRESSION TEST — this assertion has flipped THREE times, and the
  # history is the whole point (a three-layer failure of empty model + wrong
  # spec):
  #   Phase 1  VACUOUS   — leader-uniqueness "proven" over a space with no leader
  #   Phase 3a VIOLATED  — timers fire, election happens, and the *global*
  #                        invariant `never(count(leader) > 1)` is refuted by a
  #                        legal transient stale leader (two leaders, DIFFERENT
  #                        terms). The implementation was correct; the spec wasn't.
  #   now      PROVEN     — corrected to per-term uniqueness
  #                        (`never(exists A,B where both leader and same term)`),
  #                        which holds and is SUBSTANTIVE (leaders are reachable).
  # ----------------------------------------------------------------------

  test "REGRESSION: per-term leader uniqueness is PROVEN and substantive (was vacuous, then violated)" do
    source = File.read!("examples/raft_cluster.vor")

    # Timers on (default): the corrected per-term invariant holds, and it is a
    # genuine, non-vacuous result — leaders are actually reachable.
    assert {:ok, status, stats} =
             Explorer.check_file(source,
               max_depth: 40,
               max_states: 5_000_000,
               integer_bound: 2,
               max_queue: 2,
               symmetry: false
             )

    assert status in [:proven, :bounded]
    assert [verdict] = stats.vacuity
    assert verdict.relevance == :substantive
    assert verdict.subject_true_count > 0

    # `:leader` is genuinely reachable — this is not a vacuous pass.
    roles =
      stats.state_map
      |> Map.values()
      |> Enum.flat_map(fn ps -> Enum.map(ps.agents, fn {_n, s} -> Map.get(s, :role) end) end)
      |> MapSet.new()

    assert MapSet.member?(roles, :leader)

    # Contrast: with timers OFF (the old blind mode) no leader is reachable, so
    # the very same invariant is vacuous — the pass would be untested.
    assert {:error, :vacuous_proven, _names, vstats} =
             Explorer.check_file(source, max_depth: 10, max_states: 50_000, symmetry: false, fire_timers: false)

    assert [%{relevance: :vacuous}] = vstats.vacuity
  end
end
