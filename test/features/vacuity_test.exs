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
  # THE REGRESSION TEST — this is the one that would have caught the shipped
  # bug: Raft "at most one leader" proven over a space where no leader exists.
  # ----------------------------------------------------------------------

  test "REGRESSION: Raft leader-uniqueness is reported VACUOUS, not a clean proof" do
    # The shipped example declares "at most one leader" — the property the
    # original Raft result claimed to prove. No injection: this is the real file.
    source = File.read!("examples/raft_cluster.vor")

    # Fail-closed: the vacuous `proven` claim is now an error, not `Proven ✓`.
    assert {:error, :vacuous_proven, ["at most one leader"], stats} =
             Explorer.check_file(source, max_depth: 10, max_states: 50_000, symmetry: false)

    assert [verdict] = stats.vacuity
    assert verdict.relevance == :vacuous
    assert verdict.subject == "role == :leader"
    assert verdict.subject_true_count == 0

    # And the coverage report names exactly why: leader/candidate never reached.
    assert [%{field: :role, unreached: unreached}] = stats.coverage.unreached_states
    assert :leader in unreached
    assert :candidate in unreached
  end
end
