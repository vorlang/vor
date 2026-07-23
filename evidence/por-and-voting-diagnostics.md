# Diagnostics: POR independence vs. symmetry bug, and Raft's vote gating

Two soundness diagnostics. No code changed.

---

## Question 1 — Does POR's independence inherit the symmetry-fingerprint bug?

### Which representation does POR actually use?

Its own notion — **not** a fingerprint at all for the independence/visibility
decision. `Vor.Explorer.POR.ample/5` groups successors by target agent and tests
visibility by comparing agent field *values*:

```elixir
# por.ex
defp target(%ProductState{last_action: action}) do
  case action do
    {:deliver, _from, to, _msg} -> to
    {:external, agent, _msg} -> agent
    {:timer, agent, _tag} -> agent
    _ -> nil
  end
end

defp visible?(%ProductState{} = succ, %ProductState{} = parent, invariant_fields) do
  case target(succ) do
    nil -> true
    agent ->
      p = Map.get(parent.agents, agent, %{})
      s = Map.get(succ.agents, agent, %{})
      Enum.any?(invariant_fields, fn f -> Map.get(p, f) != Map.get(s, f) end)
  end
end
```

The only place a fingerprint appears is the **cycle proviso** (`all_new?`), and
the fingerprint passed in is chosen by the BFS:

```elixir
# explorer.ex
POR.ample(successors, state, stats.invariant_fields, visited,
  fn s -> fingerprint(s, symmetry) end)
```

`fingerprint(s, true)` is the buggy `Symmetry.canonical_fingerprint/1`;
`fingerprint(s, false)` is `ProductState.fingerprint/1`.

### Does the independence *argument* depend on the symmetry collapse?

No. The argument rests on the **faithful** multiset, `ProductState.fingerprint/1`,
which keeps endpoints intact:

```elixir
# product_state.ex — faithful: sorts the whole {from, to, msg} tuples
def fingerprint(%__MODULE__{agents: agents, pending_messages: pending}) do
  {agents, Enum.sort(pending)}
end
```

versus the unsound symmetry one, whose bug is the *uncoordinated* collapse
(strips endpoints, and permutes agents independently of messages):

```elixir
# symmetry.ex — strips from/to, keeps payload verbatim (the known bug)
canonical_messages =
  pending
  |> Enum.map(fn {_from, _to, msg} -> msg end)
  |> Enum.sort()
```

Two events at different agents commute under the *faithful* representation
(disjoint local state; handlers process one message and never read the mailbox;
the queue is an order-independent multiset). The commutation holds **with
endpoints fully intact** — it does not need, and does not use, the
endpoint-stripping that makes `canonical_fingerprint` unsound.

### Verdict for Q1

**POR's soundness is independent of the symmetry bug.** POR decides independence
from `last_action` targets and field values, never from a message fingerprint;
its commutation argument uses the faithful multiset. When symmetry is off (all
soundness-gate and measurement runs), `canonical_fingerprint` is never invoked.
When symmetry is on, the buggy fingerprint only feeds POR's cycle-proviso
visited-check — and a *coarser* fingerprint there makes `all_new?` harder to
satisfy, so POR reduces **less** (more conservative), never less sound. The two
concerns are genuinely separate; POR inherits no assumption from the symmetry
code.

### But — a *different* soundness gap in POR's independence (found while checking)

POR's independence ("different target agent ⇒ commute") is **false in general**,
for a reason unrelated to endpoints: the **lossy bounded queue is
order-sensitive**.

```elixir
# successor.ex
new_pending = cap_queue(remaining_pending ++ outgoing, max_queue)
defp cap_queue(queue, max_queue) when ... , do: Enum.take(queue, max_queue)
```

`cap_queue` keeps the *first* `max_queue` messages and drops the tail. When the
queue is saturated and two events produce **asymmetric** numbers of outgoing
messages, the two delivery orders drop *different* messages, so they do not
commute. Constructed and **empirically confirmed** (3 fully-connected `Node`s,
`max_queue: 2`; `:loud` broadcasts, `:quiet` is a noop; pending = one `:loud`→a
and one `:quiet`→b):

```
deliver loud→a THEN quiet→b  →  pending [{a,b,x}]              (x→c was dropped)
deliver quiet→b THEN loud→a  →  pending [{a,b,x}, {a,c,x}]     (both survive)
commute (fingerprints equal)?  false
```

The state `{x→b, x→c}` is reachable **only** via the b-first order. POR treats
`deliver→a` and `deliver→b` as independent and may explore only one order, so it
can drop that state (and anything reachable only through it).

**Scope / why the gate still passed.** In the real examples POR only reduces on
*invisible* events (those not touching `role`/`current_term`); the gate showed
identical verdicts because the examples don't exercise a verdict-changing
instance of this (e.g. the queue-overflowing broadcasts in Raft — `request_vote`,
`append_entries` — also change `current_term`, i.e. are *visible*, so POR does
not reduce across them). But the independence assumption is provably false, so
POR's current soundness rests on "the examples don't hit it" — exactly the class
of risk this project exists to eliminate. This is a **POR-only** issue: the plain
(non-POR) BFS explores both orders and is unaffected; it is also **separate from
the symmetry bug**. Worth filing.

*(Possible conservative fixes, for later: treat two events as dependent whenever
delivering either could overflow `max_queue` — i.e. only call them independent
when `length(pending) + max(outgoing counts) ≤ max_queue`; or make the queue a
true multiset with a canonical/deterministic drop policy so truncation is
order-independent.)*

---

## Question 2 — Does the Raft example gate voting on `voted_for`?

### The vote-granting handlers (quoted)

```vor
on {:request_vote, term: T, candidate_id: C, ...} when role == :follower and T > current_term do
  transition current_term: T
  transition voted_for: C
  send C {:vote_granted, term: T, voter: node_id}
end

on {:request_vote, term: T, candidate_id: C, ...} when role == :follower and T <= current_term do
  send C {:vote_denied, term: current_term}
end
```

and the only other granting handler (a leader stepping down):

```vor
on {:request_vote, term: T, candidate_id: C, ...} when role == :leader and T > current_term do
  transition role: :follower
  transition current_term: T
  transition voted_for: C
  send C {:vote_granted, term: T, voter: node_id}
end
```

**The guard never reads `voted_for`.** Every granting guard is `role == … and
T > current_term`. `voted_for` is *written* (`transition voted_for: C`) but read
by no guard, no conditional, and no transition to a tracked field.

### Can a node vote twice in the same term?

**No — but the mechanism is `current_term`, not `voted_for`.** Granting requires
`T > current_term` *and* sets `current_term := T`. So after a node grants a vote
for term `T`, its `current_term` is `T`; any further `request_vote` at the same
`T` fails `T > current_term` (`T > T` is false) and is denied. Every one of the
handlers that emits `vote_granted` bumps `current_term` to `T`, so a node grants
at most once per term value. (`current_term` is monotone non-decreasing across
all handlers.)

### Why COI abstracted `voted_for`

Confirmed: because no tracked-field decision reads it. The cone-of-influence
closure keeps a field only if it is referenced by the invariant or feeds a guard
/ conditional gating a transition to a tracked field. `voted_for` is written but
never read, so it influences nothing tracked — COI correctly drops it. Abstracting
it does not change any behavior, precisely because the vote decision is made on
`current_term`, not `voted_for`.

### Verdict for Q2

**The example does not gate votes on `voted_for`.** `voted_for` is vestigial
(written, never read); COI correctly abstracts it. However, a node still cannot
vote twice in a term — double-voting is prevented by **`current_term` monotonicity
plus the strict `T > current_term` guard**, not by `voted_for`.

So the per-term leader-uniqueness proof is **not** implementation-shaped in the
"a node can vote many times" sense (it can't). The load-bearing property —
one vote per term, hence quorum intersection forbids two same-term majorities —
genuinely holds and is exercised, so the proof *does* reflect Raft's actual safety
argument. But the model implements that property via a **different, stricter**
mechanism than canonical Raft: it grants only on a *strictly higher* term (it
never grants a same-term vote at all), whereas real Raft grants a same-term vote
when `votedFor ∈ {null, candidate}`. The safety conclusion is Raft-meaningful;
the vote-gating field is not the canonical one, and the model is a simplification
(stricter on granting) of real Raft.

Neither of the two offered verdicts is exactly right: it is **"does not gate on
`voted_for`, but double-voting is still prevented (via `current_term`), so the
per-term proof reflects the real one-vote-per-term safety argument — implemented
by a stricter, non-canonical mechanism."**
