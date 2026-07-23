defmodule Vor.Explorer.POR do
  @moduledoc """
  Partial-order reduction (static, ample/persistent sets) for the product-state
  BFS.

  ## Why it can be sound here

  Every successor is produced by exactly one event aimed at exactly one agent
  (`last_action` is `{:deliver, _, to, _}`, `{:external, agent, _}`, or
  `{:timer, agent, _}`), a handler mutates only that target agent's local state,
  and pending messages are compared as an unordered multiset by
  `ProductState.fingerprint/1`. Under those semantics **two events aimed at
  different agents are independent**: they commute to the same fingerprint, and
  neither consumes the other's triggering message nor disables the other. That
  is the dependency relation POR needs.

  ## The ample set we pick

  At a state we look for a single agent `g` whose *entire* set of enabled events
  is **invisible** — none of them changes a field the safety invariants
  reference (so checking the invariant before vs. after any of them is
  equivalent). If such a `g` exists and the **cycle proviso** below holds, we
  explore only `g`'s events and defer the rest; the deferred events stay enabled
  and are explored from `g`'s successors (independence guarantees they are not
  lost). Otherwise we explore the full enabled set.

  Ample-set conditions (Clarke–Grumberg–Peled), specialized:

    * **C0/C1 (persistent):** `g`'s events are dependent only on other `g`
      events (same agent); every deferred event targets a *different* agent and
      is therefore independent of the ample set.
    * **C2 (invisible):** we only reduce to a proper subset when all ample
      events are invisible w.r.t. the invariant's atomic propositions, so
      deferring visible events cannot hide a violating state.
    * **C3 (cycle proviso):** we reduce only when every ample successor is a
      *new* (unvisited) state. The moment an ample event would close back onto a
      visited state we expand fully — in a finite state space this prevents any
      event from being deferred forever (the "ignoring problem").

  ## Conservatism

  Over-approximating the dependency relation (treating independent events as
  dependent) only costs exploration; under-approximating it drops states and is
  unsound. When in doubt this module treats events as dependent (full
  expansion). DPOR — dynamic race detection with backtracking, which does not
  need the invisibility restriction — would slot in as a replacement for
  `ample/6`; it is intentionally not built here (see `evidence/`).
  """

  alias Vor.Explorer.ProductState

  @doc """
  Select the ample set from `successors` (already post-processed, filtered, and
  deduped by the caller).

    * `parent` — the state being expanded.
    * `invariant_fields` — the set of agent field names the safety invariants
      reference (their atomic propositions). A successor is *visible* if it
      changed one of these on its target agent.
    * `visited` — the BFS visited fingerprint set (for the cycle proviso).
    * `fingerprint` — the fingerprint function the BFS uses (symmetry-aware).

  Returns a subset of `successors` (or all of them). Never returns more than it
  was given, and returns `[]` only when given `[]`.
  """
  def ample(successors, parent, invariant_fields, visited, fingerprint)
      when is_list(successors) do
    case successors do
      [] ->
        []

      [_only] ->
        successors

      _ ->
        # Queue-safety gate. The independence relation ("different target agent
        # ⇒ commute") holds only while the bounded queue does not truncate: the
        # `cap_queue` drop keeps the *first* `max_queue` messages, so two orders
        # that saturate the queue can drop different tails and NOT commute (a
        # `deliver→a` that overflows can leave a `deliver→b` reachable-or-not
        # depending on order). Two fixes were considered:
        #
        #   (a) [chosen] treat any queue-growing or truncating event as
        #       dependent — reduce only when no enabled event grows or overflows
        #       the queue. POR-only, keeps the model's lossy semantics intact.
        #       Reduction cost: no reduction across broadcast/gossip events at a
        #       near-full queue (they grow it); the common invisible non-growing
        #       deliveries still reduce.
        #   (b) [rejected] make `cap_queue`'s drop order-independent (drop by a
        #       canonical key instead of the tail). That changes the MODEL — it
        #       alters which messages the lossy network drops, shifting every
        #       (non-POR) result and state count, and could itself mask or move
        #       verdicts. Out of scope: we must not restore reduction by
        #       changing what the checker verifies.
        #
        # Conservative bias: over-approximating dependency (option a) only costs
        # exploration; under-approximating drops states. When any event is not
        # capacity-inert we expand fully.
        if Enum.all?(successors, &capacity_inert?(&1, parent)) do
          reduce(successors, parent, invariant_fields, visited, fingerprint)
        else
          successors
        end
    end
  end

  # An event is capacity-inert when it neither overflowed the queue (`cap_queue`
  # dropped nothing) nor grew it. If every enabled event is capacity-inert the
  # queue is non-increasing and untruncated along the reduction, so the lossy
  # truncation cannot introduce an order dependence — commutation holds.
  defp capacity_inert?(%ProductState{queue_truncated: true}, _parent), do: false

  defp capacity_inert?(%ProductState{pending_messages: p}, %ProductState{pending_messages: pp}),
    do: length(p) <= length(pp)

  defp reduce(successors, parent, invariant_fields, visited, fingerprint) do
    groups = Enum.group_by(successors, &target/1)

    candidate =
      Enum.find_value(groups, fn
        {nil, _group} ->
          # No identifiable target (should not happen) — never reduce on it.
          nil

        {_agent, group} ->
          all_invisible? = Enum.all?(group, &(not visible?(&1, parent, invariant_fields)))

          all_new? =
            Enum.all?(group, fn s -> not MapSet.member?(visited, fingerprint.(s)) end)

          if all_invisible? and all_new?, do: group, else: nil
      end)

    candidate || successors
  end

  # The single agent an event is aimed at.
  defp target(%ProductState{last_action: action}) do
    case action do
      {:deliver, _from, to, _msg} -> to
      {:external, agent, _msg} -> agent
      {:timer, agent, _tag} -> agent
      _ -> nil
    end
  end

  # A successor is visible iff its target agent's value for some invariant field
  # differs from the parent's. (Only the target agent's state can change, so we
  # only compare that agent.)
  defp visible?(%ProductState{} = succ, %ProductState{} = parent, invariant_fields) do
    case target(succ) do
      nil ->
        true

      agent ->
        p = Map.get(parent.agents, agent, %{})
        s = Map.get(succ.agents, agent, %{})
        Enum.any?(invariant_fields, fn f -> Map.get(p, f) != Map.get(s, f) end)
    end
  end
end
