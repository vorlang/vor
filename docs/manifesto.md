# The Vor Manifesto

*Named for the Norse goddess who witnesses oaths and punishes oath-breakers*

---

We are building software wrong.

Not because our tools are bad — they are extraordinary. Not because our engineers are unskilled — they are brilliant. We are building software wrong because we are still writing instructions for machines when we should be declaring truths about systems.

Every mainstream programming language assumes a human will specify *how* a system behaves, step by step, in explicit detail. This assumption shaped sixty years of language design, tooling, and practice. It gave us functions, classes, modules, version control, code review, test suites, and CI pipelines — an enormous apparatus built around one premise: that a human mind must bridge the gap between intent and execution.

That premise is no longer true.

AI can bridge that gap. But only if we stop asking it to write code in languages designed for humans and start giving it something better to work with: precise declarations of what must be true, what must never happen, and what must eventually happen. Not instructions. Oaths.

---

**We believe the specification is the program.** There should be no separate implementation to maintain, review, or debug. The human declares the system's properties. The machine produces an execution that satisfies them. If the properties change, the execution is re-derived. The spec is the only artifact that matters.

**We believe relations are more fundamental than functions.** A function imposes direction: input to output. A relation declares an association that can be traversed any way the system needs. Most knowledge is naturally relational. We have been forcing it into a directional mold because our languages required it, not because the problem demanded it.

**We believe correctness guarantees must be explicit.** Every property of a system should be labeled with the strength of its guarantee: proven by the compiler, checked against synthesis output, or monitored at runtime. Mixing these — or worse, leaving them implicit — creates false confidence. We would rather have an honest "monitored" than a dishonest "proven."

**We believe failure is a first-class concept.** Synthesis can fail to produce an implementation. Invariants can be violated at runtime. Specifications can contradict themselves. A language that doesn't define what happens in these cases is a language that pretends they won't occur. They will.

**We believe AI should be bounded, not trusted.** AI synthesis operates within declared constraints. Its output is verified before deployment. It doesn't make architectural decisions the human didn't authorize. The AI is powerful, but it is not in charge. The spec is in charge.

**We believe the runtime matters.** Grand visions fail without pragmatic foundations. We build on the BEAM — the same virtual machine that runs Erlang and Elixir — because it provides concurrency, fault tolerance, hot code reloading, and distribution that have been proven in production for thirty years. We are radical in our language design and conservative in our runtime.

**We believe escape hatches are not defeat.** Not everything belongs in a declarative specification. Performance-critical inner loops, raw system integration, and unconstrained side effects sometimes need human-authored code. Vor provides explicit boundaries where Erlang and Elixir take over — untrusted by default, monitored at the boundary, seamless in practice.

---

Layering AI onto mainstream languages produces code faster. It does not produce better systems. The generated code inherits every failure mode of the host language. The review burden shifts from writing to reading — and reading code you didn't write is harder than writing it yourself. Tests generated alongside code validate assumptions against themselves. The spec-implementation gap doesn't close; it fills with unreviewed decisions that compound into drift.

We do not believe this is the future. We believe it is the transition.

The future is a language where humans declare what must be true and machines make it so — where the declaration is precise enough to be verified and the synthesis is constrained enough to be trusted. Where the oaths you swear about your system are witnessed, checked, and enforced.

That language is Vor.

---

*vorlang.org · Design phase · Open source*
