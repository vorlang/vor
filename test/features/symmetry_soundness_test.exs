defmodule Vor.SymmetrySoundnessTest do
  @moduledoc """
  Investigation harness (NOT a fix). Tests the hypothesis that
  `Vor.Explorer.Symmetry.canonical_fingerprint/1` is not a valid orbit
  representative under the agent-permutation group S_n, and that the resulting
  fingerprint collisions can prune a real safety violation out of the BFS.

  These tests are written to OBSERVE current behavior. Test 1 is expected to
  FAIL its second assertion (the collision assertion) if the hypothesis holds;
  it is written so the failure message prints the two colliding fingerprints.
  Test 2 measures whether the collision actually hides a counterexample.

  No source under lib/ is modified by this file.
  """
  use ExUnit.Case, async: false

  alias Vor.Explorer
  alias Vor.Explorer.{ProductState, Symmetry}

  # A single in-flight message, IDENTICAL in content across the two states.
  # Shape matches what the explorer stores: {tag, %{field => value}}.
  @msg {:vote_granted, %{term: 1, voter: :node3}}

  # ----------------------------------------------------------------------
  # Test 1 — fingerprint collision across distinct S_3 orbits
  # ----------------------------------------------------------------------
  #
  # Three agents with pairwise-distinct local states => trivial stabilizer,
  # so the ONLY permutation fixing the agent map is the identity. Any
  # difference in the message endpoints therefore cannot be absorbed by a
  # permutation: the two states are in different S_3 orbits.
  # CHARACTERIZATION TEST for a KNOWN, UNFIXED bug (see KNOWN_ISSUES.md §2:
  # "Symmetry canonicalization is not orbit-exact"). It asserts the *current,
  # incorrect* behavior — the two distinct-orbit states DO collide — so the
  # suite stays green while the defect is documented. When the canonicalization
  # is fixed (Phase 3), this test will start failing, which is the signal to
  # update it to assert the corrected (non-colliding) behavior.
  test "KNOWN BUG: canonical_fingerprint collides two states from different S3 orbits" do
    agents = %{
      node1: %{role: :leader},
      node2: %{role: :candidate},
      node3: %{role: :follower}
    }

    # Same agents, same message content; message recipient differs only.
    a = %ProductState{agents: agents, pending_messages: [{:node3, :node2, @msg}]}
    b = %ProductState{agents: agents, pending_messages: [{:node3, :node1, @msg}]}

    plain_a = ProductState.fingerprint(a)
    plain_b = ProductState.fingerprint(b)
    canon_a = Symmetry.canonical_fingerprint(a)
    canon_b = Symmetry.canonical_fingerprint(b)

    IO.puts("""

    ── Test 1 fingerprints ───────────────────────────────────────────────
    ProductState.fingerprint(a)      = #{inspect(plain_a)}
    ProductState.fingerprint(b)      = #{inspect(plain_b)}
    Symmetry.canonical_fingerprint(a)= #{inspect(canon_a)}
    Symmetry.canonical_fingerprint(b)= #{inspect(canon_b)}
    canonical collide? #{canon_a == canon_b}
    ──────────────────────────────────────────────────────────────────────
    """)

    # Sanity: the non-symmetric fingerprint MUST distinguish them.
    assert plain_a != plain_b,
           "non-symmetric fingerprint unexpectedly merged two distinct states"

    # KNOWN BUG (asserted as current behavior): the two states lie in different
    # S3 orbits (three pairwise-distinct agent states => trivial stabilizer, so
    # only the identity fixes the agent map, and the message endpoints differ),
    # yet canonical_fingerprint/1 maps them to the SAME value. A correct orbit
    # representative would keep them distinct. When Phase 3 fixes this, flip the
    # assertion to `refute canon_a == canon_b`.
    assert canon_a == canon_b,
           "expected the known cross-orbit collision; canonicalization may have been fixed — update this test"
  end

  # ----------------------------------------------------------------------
  # Test 2 — does the collision hide a real violation?
  # ----------------------------------------------------------------------
  #
  # Weaken the Raft majority gate so a two-leader state is genuinely
  # reachable, then compare exploration with symmetry OFF vs ON. If symmetry
  # OFF finds the "at most one leader" violation but symmetry ON reports
  # proven, the reduction pruned the path to the bug => unsound.
  #
  # The weakening is an IN-MEMORY string edit of the example source; it does
  # NOT touch examples/raft_cluster.vor on disk.
  test "weakened-majority Raft: does symmetry prune the two-leader counterexample?" do
    raft_source = File.read!("examples/raft_cluster.vor")

    # ===== TEMPORARY, CLEARLY-MARKED WEAKENING (in memory only) =====
    # Original gate: `if new_votes > half do` (strict majority).
    # Weakened gate: `if new_votes >= 1 do` (any single vote => leader),
    # which makes a two-leader state reachable.
    weakened =
      String.replace(raft_source, "if new_votes > half do", "if new_votes >= 1 do")

    assert weakened != raft_source, "expected to find the majority gate to weaken"
    # ===== END WEAKENING =====

    # Inject the system-level safety invariant (the example file has none),
    # exactly as the existing suite does.
    augmented =
      String.replace(weakened, ~r/\nend\s*\z/, """

        safety "at most one leader" proven do
          never(count(agents where role == :leader) > 1)
        end
      end
      """)

    opts = [max_depth: 30, max_states: 50_000]

    off = Explorer.check_file(augmented, Keyword.put(opts, :symmetry, false))
    on = Explorer.check_file(augmented, Keyword.put(opts, :symmetry, :auto))

    IO.puts("""

    ── Test 2 results (weakened majority) ────────────────────────────────
    symmetry OFF : #{summarize(off)}
    symmetry ON  : #{summarize(on)}
    ──────────────────────────────────────────────────────────────────────
    """)

    off_violation? = match?({:error, :violation, "at most one leader", _, _}, off)
    on_violation? = match?({:error, :violation, "at most one leader", _, _}, on)

    IO.puts("symmetry OFF found violation? #{off_violation?}")
    IO.puts("symmetry ON  found violation? #{on_violation?}")

    # ── Root-cause probe ────────────────────────────────────────────────
    # Test 2 is INCONCLUSIVE: neither run finds a violation, and the state
    # counts are IDENTICAL to the un-weakened baseline (8008 / 1001), so the
    # weakened gate was never exercised. The probe below explains why: across
    # the whole explored space every node stays :follower, so no leader is
    # ever elected and the majority gate lives in unreachable (during BFS)
    # code. The explorer's successor relation only delivers messages +
    # injects representative externals; it never fires the resilience/timeout
    # transition that moves :follower -> :candidate.
    probe =
      String.replace(raft_source, ~r/\nend\s*\z/, """

        safety "all nodes always follower" proven do
          never(count(agents where role == :follower) < 3)
        end
      end
      """)

    probe_off = Explorer.check_file(probe, Keyword.put(opts, :symmetry, false))
    IO.puts("probe 'all nodes always follower' (symmetry off): #{summarize(probe_off)}")

    # PROVEN => the predicate `count(role==:follower) < 3` is never reached,
    # i.e. all three nodes are followers in every explored state.
    assert match?({:ok, :proven, _}, probe_off),
           "expected all nodes to remain :follower; if this changed, re-examine Test 2"

    # Document the observed (inconclusive-for-impact) reality: no leader is
    # reachable, so neither run reports a violation. This does NOT vindicate
    # symmetry — it means the Raft example cannot exercise the collision.
    refute off_violation?
    refute on_violation?
  end

  defp summarize({:ok, status, stats}),
    do: "#{status} (#{stats.states_explored} states, depth #{stats.max_depth_reached}, symmetry=#{stats.symmetry})"

  defp summarize({:error, :violation, name, trace, stats}),
    do: "VIOLATION #{inspect(name)} (#{stats.states_explored} states, trace len #{length(trace)}, symmetry=#{stats.symmetry})"

  defp summarize(other), do: inspect(other)
end
