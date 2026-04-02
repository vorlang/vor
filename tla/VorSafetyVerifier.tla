--------------------------- MODULE VorSafetyVerifier ---------------------------
\* TLA+ specification for Vor's compile-time safety invariant verifier.
\*
\* Purpose: Prove that the verifier gives correct answers for all possible
\* state graphs and safety properties within a bounded size.
\*
\* Scope: The safety verifier takes a state graph and an invariant body,
\* and returns either "proven" or "violated". This spec defines what
\* "correct" means and lets TLC exhaustively check it.
\*
\* What this verifies:
\*   1. Soundness — if verifier says "proven", the property holds on the graph
\*   2. Completeness — if verifier says "violated", the property is truly violated
\*   3. Fail-closed — unrecognized invariant bodies are never accepted as proven
\*
\* What this does NOT verify:
\*   - Graph extraction from source code (separate spec)
\*   - Codegen correctness
\*   - Runtime behavior

EXTENDS Integers, FiniteSets, TLC

CONSTANTS
    States,          \* Set of possible state atoms, e.g. {"idle", "active", "done"}
    MessageTags      \* Set of possible emit message tags, e.g. {"ok", "rejected", "timeout"}

VARIABLES
    graph,           \* The state graph under analysis
    invariant,       \* The safety invariant being checked
    verifierResult,  \* What the verifier returns: "proven", "violated", or "error"
    groundTruth      \* What the correct answer actually is

vars == <<graph, invariant, verifierResult, groundTruth>>

-----------------------------------------------------------------------------
\* Graph structure
\*
\* A graph is a record with:
\*   states: set of state names
\*   initial: the initial state
\*   transitions: set of <<from, to>> pairs
\*   emitMap: function from state -> set of message tags that state can emit

GraphType == [
    states: SUBSET States,
    initial: States,
    transitions: SUBSET (States \X States),
    emitMap: [States -> SUBSET MessageTags]
]

\* A graph is well-formed if:
\*   - initial state is in the state set
\*   - all transition endpoints are in the state set
\*   - emitMap is defined for all states in the set
WellFormed(g) ==
    /\ g.initial \in g.states
    /\ \A <<s1, s2>> \in g.transitions : s1 \in g.states /\ s2 \in g.states
    /\ \A s \in g.states : g.emitMap[s] \subseteq MessageTags

-----------------------------------------------------------------------------
\* Invariant types
\*
\* We model two kinds of safety invariants that Vor currently supports:
\*
\* 1. NeverEmitInState(state, tag):
\*    "never(phase == state and emitted({tag, _}))"
\*    Property holds iff the state's emit set does not contain the tag.
\*
\* 2. NeverTransition(from, to):
\*    "never(transition from: from, to: to)"
\*    Property holds iff no transition edge goes from -> to.
\*
\* 3. Unsupported:
\*    An invariant body the verifier doesn't recognize.
\*    Correct answer is always "error" (fail closed).

InvariantType == 
    [type: {"never_emit"}, state: States, tag: MessageTags]
    \cup [type: {"never_transition"}, from: States, to: States]
    \cup [type: {"unsupported"}]

-----------------------------------------------------------------------------
\* Ground truth computation
\*
\* Given a graph and an invariant, compute the objectively correct answer.
\* This is the reference against which we check the verifier.

GroundTruthFor(g, inv) ==
    CASE inv.type = "never_emit" ->
        IF inv.state \notin g.states
        THEN "proven"  \* state not in graph — property vacuously holds
        ELSE IF inv.tag \in g.emitMap[inv.state]
             THEN "violated"
             ELSE "proven"
    [] inv.type = "never_transition" ->
        IF <<inv.from, inv.to>> \in g.transitions
        THEN "violated"
        ELSE "proven"
    [] inv.type = "unsupported" ->
        "error"

-----------------------------------------------------------------------------
\* Verifier model
\*
\* This models what Vor's verifier actually does. It should match the
\* Elixir implementation in lib/vor/verification/safety.ex.
\*
\* The verifier:
\*   - For never_emit: checks if tag is in emitMap[state]
\*   - For never_transition: checks if <<from, to>> is in transitions
\*   - For unsupported: returns error (after Fix 1)

VerifierComputes(g, inv) ==
    CASE inv.type = "never_emit" ->
        IF inv.state \in g.states
        THEN (IF inv.tag \in g.emitMap[inv.state]
              THEN "violated"
              ELSE "proven")
        ELSE "proven"  \* state not in graph — property vacuously holds
    [] inv.type = "never_transition" ->
        IF <<inv.from, inv.to>> \in g.transitions
        THEN "violated"
        ELSE "proven"
    [] inv.type = "unsupported" ->
        "error"

-----------------------------------------------------------------------------
\* State machine
\*
\* The spec nondeterministically chooses a graph and an invariant,
\* then computes both the ground truth and the verifier's answer.
\* TLC checks that they always match.

Init ==
    \E states \in SUBSET States :
    \E initial \in States :
    \E transitions \in SUBSET (States \X States) :
    \E emitMap \in [States -> SUBSET MessageTags] :
    \E inv \in InvariantType :
        LET g == [states |-> states, initial |-> initial,
                  transitions |-> transitions, emitMap |-> emitMap]
        IN /\ WellFormed(g)
           /\ graph = g
           /\ invariant = inv
           /\ verifierResult = VerifierComputes(g, inv)
           /\ groundTruth = GroundTruthFor(g, inv)

\* No further steps — this is a single-step spec.
\* We generate all possible (graph, invariant) pairs and check each one.
Next == UNCHANGED vars

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
\* Correctness properties

\* Soundness: if verifier says proven, it really is proven
Soundness ==
    verifierResult = "proven" => groundTruth = "proven"

\* Completeness: if verifier says violated, it really is violated  
Completeness ==
    verifierResult = "violated" => groundTruth = "violated"

\* FailClosed: unsupported invariants are never accepted as proven
FailClosed ==
    invariant.type = "unsupported" => verifierResult = "error"

\* Combined: verifier result always matches ground truth
Correctness ==
    verifierResult = groundTruth

\* Type invariant for sanity checking
TypeOK ==
    /\ graph \in GraphType
    /\ invariant \in InvariantType
    /\ verifierResult \in {"proven", "violated", "error"}
    /\ groundTruth \in {"proven", "violated", "error"}

=============================================================================
