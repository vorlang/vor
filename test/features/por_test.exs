defmodule Vor.Features.PORTest do
  @moduledoc """
  Phase 3c — partial-order reduction soundness.

  POR is another reduction that silently drops states; the whole project exists
  because a reduction (symmetry, on a degenerate space) produced a wrong number
  and nobody noticed. So the bar is: **POR must never change a verdict or a
  relevance label, and must never hide a counterexample.** These tests compare
  POR-on against POR-off on every relevant shape.
  """
  use ExUnit.Case, async: true

  alias Vor.Explorer

  @raft File.read!("examples/raft_cluster.vor")
  # the global (mis-specified, violated) invariant, for counterexample survival
  @raft_global String.replace(
                 @raft,
                 ~r/  safety "at most one leader per term".*?\n  end/s,
                 "  safety \"global\" proven do\n    never(count(agents where role == :leader) > 1)\n  end"
               )

  defp categorize(res) do
    stats = res |> Tuple.to_list() |> List.last()

    verdict =
      case {elem(res, 0), elem(res, 1)} do
        {:error, :violation} -> :violated
        {:error, :vacuous_proven} -> :vacuous_proven
        {:ok, status} -> status
        other -> other
      end

    relevance =
      case is_list(Map.get(stats, :vacuity)) && stats.vacuity != [] do
        true -> hd(stats.vacuity).relevance
        _ -> :none
      end

    {verdict, relevance, (is_map(stats) && stats.states_explored) || 0}
  end

  defp assert_por_equivalent(source, opts) do
    {v_off, r_off, n_off} = categorize(Explorer.check_file(source, Keyword.put(opts, :por, false)))
    {v_on, r_on, n_on} = categorize(Explorer.check_file(source, Keyword.put(opts, :por, true)))

    assert v_on == v_off, "POR changed the verdict: #{inspect(v_off)} -> #{inspect(v_on)}"
    assert r_on == r_off, "POR changed the relevance: #{inspect(r_off)} -> #{inspect(r_on)}"
    assert n_on <= n_off, "POR increased the state count (#{n_off} -> #{n_on})"
    {v_on, n_off, n_on}
  end

  test "POR preserves the Raft per-term PROOF (verdict + substantive relevance), and reduces" do
    {verdict, n_off, n_on} =
      assert_por_equivalent(@raft,
        max_depth: 40, max_queue: 2, integer_bound: 2, max_states: 2_000_000, symmetry: false
      )

    assert verdict == :proven
    # POR should actually help here (not merely be neutral).
    assert n_on < n_off
  end

  test "POR preserves the Raft counterexample (global invariant stays VIOLATED)" do
    {verdict, _, _} =
      assert_por_equivalent(@raft_global,
        max_depth: 40, max_queue: 2, integer_bound: 2, max_states: 2_000_000, symmetry: false, allow_vacuous: true
      )

    assert verdict == :violated
  end

  test "POR preserves vacuity: with timers off, Raft stays vacuous under POR" do
    {verdict, r_off, _} = categorize(Explorer.check_file(@raft, max_depth: 40, max_queue: 2, integer_bound: 2, symmetry: false, allow_vacuous: true, fire_timers: false, por: false))
    {verdict2, r_on, _} = categorize(Explorer.check_file(@raft, max_depth: 40, max_queue: 2, integer_bound: 2, symmetry: false, allow_vacuous: true, fire_timers: false, por: true))

    assert r_off == :vacuous
    assert r_on == :vacuous
    assert verdict == verdict2
  end

  test "POR composes with symmetry (verdict + relevance still preserved)" do
    assert_por_equivalent(@raft,
      max_depth: 30, max_queue: 2, integer_bound: 2, max_states: 2_000_000, symmetry: :auto
    )
  end

  # --------------------------------------------------------------------------
  # Repositioning: a normal compile must NOT run multi-agent exploration.
  # --------------------------------------------------------------------------

  test "compiling a system block does not run the model checker" do
    {:ok, result} = Vor.Compiler.compile_system(@raft)

    # The compile result carries the parsed system IR + agents, but no
    # exploration artifacts (state_map / states_explored / vacuity). Multi-agent
    # checking only happens via `mix vor.check` / `Explorer.check_file`.
    refute Map.has_key?(result, :state_map)
    refute Map.has_key?(result, :states_explored)
    refute Map.has_key?(result, :vacuity)
    assert result.system_ir != nil
  end
end
