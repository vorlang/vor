defmodule Vor.SymmetrySoundnessTest do
  @moduledoc """
  TOMBSTONE — symmetry reduction was REMOVED on 2026-08-08, not fixed.

  This file used to be the investigation harness proving that
  `Vor.Explorer.Symmetry.canonical_fingerprint/1` was not a valid orbit
  representative under the agent-permutation group Sₙ, and that its fingerprint
  collisions could prune a real safety violation out of the BFS. The module and
  its function no longer exist, so the tests can no longer run. Their content is
  preserved here as the record; see `KNOWN_ISSUES.md` §2 (resolved-by-removal),
  `evidence/phase3a-timer-measurement.md`, and
  `evidence/por-and-voting-diagnostics.md` for the full analysis.

  There are deliberately NO runnable tests below — this is a documentation
  tombstone, not a test module.

  ## Why it was removed rather than repaired

  The canonicalization performed three *uncoordinated* collapses — (1) sorted the
  per-agent states into an unordered multiset, (2) stripped from/to endpoints
  from pending messages and bagged the payloads, (3) kept payload agent IDs
  verbatim — with no single permutation π tying them together. So it could map
  states in different Sₙ orbits to the same fingerprint and prune reachable
  states (and any counterexample reachable only through them): unsound, not
  merely imprecise. And the honest-model measurement showed a *correct* fix would
  buy only ~2× (`evidence/phase3a-timer-measurement.md`). Unsound + marginal =
  dead weight with ongoing maintenance cost, so it was deleted.

  ## Test 1 — the cross-orbit fingerprint collision (preserved counterexample)

  Message content (identical across the two states):

      @msg = {:vote_granted, %{term: 1, voter: :node3}}

  Two product states with three pairwise-distinct agent roles — a *trivial*
  stabilizer, so only the identity permutation fixes the agent map — differing
  ONLY in the recipient of one in-flight message:

      agents = %{
        node1: %{role: :leader},
        node2: %{role: :candidate},
        node3: %{role: :follower}
      }

      a = %ProductState{agents: agents, pending_messages: [{:node3, :node2, @msg}]}
      b = %ProductState{agents: agents, pending_messages: [{:node3, :node1, @msg}]}

  These lie in DIFFERENT S₃ orbits (no permutation carries `a` to `b`, because
  the agent map is fixed only by the identity and the message endpoints differ).
  The sound `ProductState.fingerprint/1` distinguished them, as it must. But
  `Symmetry.canonical_fingerprint/1` mapped both to the SAME value — a
  cross-orbit collision. Since the BFS pruned on fingerprint membership, the
  state (and any violation reachable only through it) could be dropped
  unexplored.

  The arithmetic tell: a correct quotient over S₃ (three agents) caps reduction
  at 6×. The old reduction reported 8× on the vacuous Raft fixture (1001 vs 8008
  states) — arithmetically impossible for a valid symmetry reduction, and the
  signature of over-merging across orbits.

  ## Test 2 — does the collision hide a real violation on Raft?

  The follow-up weakened Raft's majority gate (in-memory string edit, never
  touching `examples/raft_cluster.vor`) to try to make a genuine two-leader state
  reachable, then compared exploration with symmetry OFF vs ON. Finding: on that
  fixture no leader was reachable at all, so neither run reported a violation —
  the Raft example could not *exercise* the collision. That did not vindicate the
  reduction (Test 1 already proved it unsound in principle); it only meant this
  particular example was not a witness. Full write-up in
  `evidence/por-and-voting-diagnostics.md`.
  """

  # No `use ExUnit.Case`, no tests: the code under test has been deleted.
end
