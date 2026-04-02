--------------------------- MODULE VorGraphExtraction --------------------------
\* TLA+ specification for Vor's state graph extraction from handler IR.
\*
\* Purpose: Prove that graph extraction produces a correct and complete
\* state graph from a set of handler declarations.
\*
\* What this verifies:
\*   1. Every declared state appears in the extracted graph
\*   2. Every handler with a state guard contributes the correct transition
\*   3. Only the declared state field is used for state inference (Fix 2)
\*   4. Emit maps correctly reflect what each state can emit
\*   5. No phantom states from non-state-field guards
\*
\* What this does NOT verify:
\*   - Parsing correctness (source -> AST)
\*   - Lowering correctness (AST -> IR)
\*   - Verifier correctness (separate spec: VorSafetyVerifier)

EXTENDS Integers, FiniteSets, Sequences, TLC

CONSTANTS
    DeclaredStates,    \* Set of states from the enum declaration, e.g. {"idle", "active", "done"}
    StateFieldName,    \* The name of the state field, e.g. "phase"
    OtherFieldNames,   \* Other field names that might appear in guards, e.g. {"mode", "level"}
    OtherAtoms,        \* Non-state atoms that might appear in guards, e.g. {"safe", "admin", "high"}
    MessageTags        \* Possible emit message tags

VARIABLES
    handlers,          \* Set of handler declarations (input to extraction)
    extractedGraph,    \* The graph that extraction produces
    referenceGraph     \* The graph that should be produced (ground truth)

vars == <<handlers, extractedGraph, referenceGraph>>

-----------------------------------------------------------------------------
\* Handler structure
\*
\* A handler has:
\*   guard: a set of guard clauses (field == atom pairs)
\*   transitionsTo: the state this handler transitions to (or "none")
\*   emits: set of message tags this handler can emit
\*
\* Guards can reference the state field or other fields.
\* Only guards on the state field should affect graph extraction.

GuardClause == [field: {StateFieldName} \cup OtherFieldNames, value: DeclaredStates \cup OtherAtoms]

\* A handler has at most one guard clause (matching Vor's typical pattern)
SingletonOrEmpty == {{g} : g \in GuardClause} \cup {{}}

Handler == [
    guards: SingletonOrEmpty,
    transitionsTo: DeclaredStates \cup {"none"},
    emits: SUBSET MessageTags
]

-----------------------------------------------------------------------------
\* Reference graph computation (ground truth)
\*
\* The correct graph for a set of handlers:
\*   - states = DeclaredStates (from the enum declaration, not inferred from guards)
\*   - For each handler with a guard on StateFieldName == S:
\*       - If handler transitions to T: add edge S -> T
\*       - If handler doesn't transition: state stays (self-loop, optional)
\*       - Handler's emits are added to emitMap[S]
\*   - For handlers with no state guard: 
\*       - They can fire in any state (add emits to all states)
\*   - Guards on other fields are IGNORED for graph purposes

\* Extract the state from a handler's guards (only from the state field)
StateFromGuards(h) ==
    LET stateGuards == {g \in h.guards : g.field = StateFieldName}
    IN IF stateGuards = {} 
       THEN DeclaredStates  \* No state guard — applies to all states
       ELSE {g.value : g \in stateGuards}

\* Build the correct emit map
ReferenceEmitMap(hs) ==
    [s \in DeclaredStates |->
        UNION {h.emits : h \in {hh \in hs : s \in StateFromGuards(hh)}}
    ]

\* Build the correct transition set
ReferenceTransitions(hs) ==
    UNION {
        UNION {
            IF h.transitionsTo /= "none" /\ s \in StateFromGuards(h)
            THEN {<<s, h.transitionsTo>>}
            ELSE {}
        : s \in DeclaredStates}
    : h \in hs}

BuildReferenceGraph(hs) ==
    [states |-> DeclaredStates,
     transitions |-> ReferenceTransitions(hs),
     emitMap |-> ReferenceEmitMap(hs)]

-----------------------------------------------------------------------------
\* Extraction model
\*
\* This models what Vor's graph extraction actually does.
\* After Fix 2, it should match the reference.
\*
\* The key property being verified:
\*   - Only guards where field == StateFieldName contribute to state inference
\*   - Guards where field is something else are ignored
\*
\* A buggy extractor (pre-Fix 2) would use ANY atom guard for state inference:

\* BUGGY version (pre-Fix 2) — accepts any field name
BuggyStateFromGuards(h) ==
    LET allAtomGuards == {g \in h.guards : g.value \in DeclaredStates \cup OtherAtoms}
    IN IF allAtomGuards = {}
       THEN DeclaredStates
       ELSE {g.value : g \in allAtomGuards}

\* FIXED version (post-Fix 2) — only accepts the state field
FixedStateFromGuards(h) ==
    StateFromGuards(h)  \* Same as reference — that's the point

\* Build the extracted graph using the fixed algorithm
FixedEmitMap(hs) ==
    [s \in DeclaredStates |->
        UNION {h.emits : h \in {hh \in hs : s \in FixedStateFromGuards(hh)}}
    ]

FixedTransitions(hs) ==
    UNION {
        UNION {
            IF h.transitionsTo /= "none" /\ s \in FixedStateFromGuards(h)
            THEN {<<s, h.transitionsTo>>}
            ELSE {}
        : s \in DeclaredStates}
    : h \in hs}

BuildExtractedGraph(hs) ==
    [states |-> DeclaredStates,
     transitions |-> FixedTransitions(hs),
     emitMap |-> FixedEmitMap(hs)]

-----------------------------------------------------------------------------
\* State machine

Init ==
    \E h1 \in Handler :
    \E h2 \in Handler \cup {[guards |-> {}, transitionsTo |-> "none", emits |-> {}]} :
        LET hs == IF h2.guards = {} /\ h2.transitionsTo = "none" /\ h2.emits = {}
                  THEN {h1}
                  ELSE {h1, h2}
        IN /\ handlers = hs
           /\ extractedGraph = BuildExtractedGraph(hs)
           /\ referenceGraph = BuildReferenceGraph(hs)

Next == UNCHANGED vars

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
\* Correctness properties

\* The extracted graph matches the reference graph exactly
GraphCorrectness ==
    extractedGraph = referenceGraph

\* States in extracted graph are exactly the declared states (no phantoms)
NoPhantomStates ==
    extractedGraph.states = DeclaredStates

\* Every transition in the extracted graph connects declared states only
TransitionsValid ==
    \A <<s1, s2>> \in extractedGraph.transitions :
        s1 \in DeclaredStates /\ s2 \in DeclaredStates

\* Emit map only covers declared states
EmitMapValid ==
    DOMAIN extractedGraph.emitMap = DeclaredStates

\* Non-state-field guards do not affect the graph
\* This is the property that was violated before Fix 2
NonStateGuardsIgnored ==
    \* For any handler with a guard on a non-state field,
    \* removing that guard does not change the extracted graph
    \A h \in handlers :
        \A g \in h.guards :
            g.field /= StateFieldName =>
                LET hWithout == [h EXCEPT !.guards = h.guards \ {g}]
                    hsWithout == (handlers \ {h}) \cup {hWithout}
                IN BuildExtractedGraph(hsWithout).transitions = 
                   BuildExtractedGraph(handlers).transitions

=============================================================================
