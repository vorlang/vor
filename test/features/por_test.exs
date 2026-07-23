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

  test "POR preserves the Raft per-term PROOF (verdict + substantive relevance)" do
    {verdict, _n_off, _n_on} =
      assert_por_equivalent(@raft,
        max_depth: 40, max_queue: 2, integer_bound: 2, max_states: 2_000_000, symmetry: false
      )

    assert verdict == :proven
    # NOTE: on honest Raft the *sound* POR reduces only marginally (~1x), because
    # the election-timeout timer broadcasts and is enabled almost everywhere, so
    # a queue-growing event blocks reduction. `assert_por_equivalent` already
    # checks states never grow; magnitude is measured in evidence/, not asserted.
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
  # REGRESSION: the lossy queue truncation is order-sensitive, so two events at
  # different agents do NOT commute when the queue is saturated with asymmetric
  # outgoing. POR must treat them as dependent (not reduce). This test builds
  # exactly that state and asserts POR.ample keeps the full set. It FAILS on the
  # pre-fix code, where POR.ample reduces the non-commuting state (2 -> 1).
  # --------------------------------------------------------------------------

  @trap_source """
  agent Node(node_id: atom) do
    state phase: :idle | :done
    protocol do
      accepts {:loud}
      accepts {:quiet}
      accepts {:x, v: integer}
      sends {:x, v: integer}
    end
    on {:loud} do
      broadcast {:x, v: 1}
    end
    on {:quiet} do
      noop
    end
    on {:x, v: V} do
      noop
    end
  end
  system S do
    agent :a, Node(node_id: :a)
    agent :b, Node(node_id: :b)
    agent :c, Node(node_id: :c)
    connect :a -> :b
    connect :a -> :c
    connect :b -> :a
    connect :b -> :c
    connect :c -> :a
    connect :c -> :b
  end
  """

  test "POR does not reduce a non-commuting saturated-queue state (queue-safety gate)" do
    alias Vor.Explorer.{ProductState, Successor, POR}
    {:ok, comp} = Vor.Compiler.compile_system(@trap_source)
    sys = comp.system_ir
    irs = Map.new(sys.agents, fn i -> {i.name, Map.get(comp.agents, i.type_name).ir} end)

    agents = %{
      a: %{phase: :idle, node_id: :a},
      b: %{phase: :idle, node_id: :b},
      c: %{phase: :idle, node_id: :c}
    }

    # Saturated queue (max_queue 2): a :loud→a (broadcasts, grows) and a :quiet→b
    # (noop). Delivering them in different orders drops different tail messages.
    parent = %ProductState{
      agents: agents,
      pending_messages: [{:src, :a, {:loud, %{}}}, {:src, :b, {:quiet, %{}}}]
    }

    deliver = fn state, to ->
      Successor.successors(state, irs, sys, max_queue: 2, fire_timers: false)
      |> Enum.find(fn s -> match?({:deliver, _, ^to, _}, s.last_action) end)
    end

    # These two different-agent deliveries genuinely do NOT commute.
    s_ab = parent |> deliver.(:a) |> deliver.(:b)
    s_ba = parent |> deliver.(:b) |> deliver.(:a)
    refute ProductState.fingerprint(s_ab) == ProductState.fingerprint(s_ba),
           "test precondition: the two orders must not commute"

    # So POR must not treat them as independent — ample must keep every successor.
    successors = Successor.successors(parent, irs, sys, max_queue: 2, fire_timers: false)
    fp = fn s -> ProductState.fingerprint(s) end
    ampled = POR.ample(successors, parent, MapSet.new(), MapSet.new(), fp)

    assert length(ampled) == length(successors),
           "POR reduced a non-commuting saturated state — the cap_queue unsoundness"
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
