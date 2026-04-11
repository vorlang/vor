# Vor — What it eliminates

## The typical distributed systems stack

Building a reliable distributed system in Java, Go, or Python requires assembling dozens of tools across multiple concerns: verification, testing, deployment, communication, observability, and resilience. Each tool has its own configuration language, its own failure modes, and its own drift vector.

Vor + BEAM replaces most of this with language-level features and runtime primitives.

## Side-by-side

### Verification and correctness

| Concern | Typical stack | Vor + BEAM |
|---|---|---|
| Design verification | TLA+ (separate spec, drifts) | `mix vor.check` (same source file) |
| Chaos testing | Chaos Monkey, Litmus, Toxiproxy | `mix vor.simulate` (built-in) |
| Contract testing | Pact, TestContainers | Protocol composition (compile-time) |
| Input validation | Joi, Zod, Bean Validation | Protocol `where` constraints |
| Static analysis | SpotBugs, PMD, linters | Formal verification + restricted language |
| Unit tests | JUnit, pytest | ExUnit + property tests (still needed) |
| Load testing | Gatling, k6 | Still needed |

### Deployment

| Concern | Typical stack | Vor + BEAM |
|---|---|---|
| Packaging | Docker images | `mix release` (self-contained binary) |
| Orchestration | Kubernetes | OTP supervision + libcluster |
| Config management | Helm charts | Mix config (no K8s = no Helm) |
| Container registry | ECR, DockerHub | Not needed (no containers) |
| Service mesh | Istio, Linkerd | Not needed (BEAM message passing) |
| Service discovery | Consul, K8s DNS | libcluster (DNS, multicast, cloud API) |
| Rolling updates | K8s rolling deploy | BEAM hot code reload |
| Infrastructure provisioning | Terraform | Still needed |
| Reverse proxy | nginx, ALB | Still needed for external HTTP |
| Auto-scaling | K8s HPA | Gap — no open-source BEAM-native solution |

### Communication

| Concern | Typical stack | Vor + BEAM |
|---|---|---|
| API definition | OpenAPI, gRPC proto | Protocol declarations (compiler-checked) |
| Serialization | JSON, Protobuf | Not needed (native BEAM terms) |
| Message queue | Kafka, RabbitMQ | Not needed (BEAM mailboxes) |
| Load balancing | nginx, ALB, service mesh | Not needed for inter-agent (direct messaging) |
| HTTP framework | Spring, Express, gRPC | Still needed for external API |

### Observability

| Concern | Typical stack | Vor + BEAM |
|---|---|---|
| Instrumentation code | OpenTelemetry SDK, manual spans | Compiler-generated (zero code) |
| Telemetry events | Manual `telemetry.execute` calls | Auto-generated for all transitions, messages, constraints |
| Sensitive data handling | Manual redaction, log scrubbing | `sensitive` field annotation (compiler-enforced) |
| Metrics backend | Prometheus, Grafana | Still needed (Vor generates events, you view them) |
| Log aggregation | ELK, Loki | Still needed at scale |

### Concurrency and fault tolerance

| Concern | Typical stack | Vor + BEAM |
|---|---|---|
| Thread management | ExecutorService, goroutines | BEAM processes (preemptive, isolated) |
| Synchronization | Locks, semaphores, mutexes | Not needed (no shared state) |
| Circuit breakers | Resilience4j, Hystrix | Vor agent (verified state machine) |
| Retry logic | Spring Retry, custom | Handler logic or supervisor restart |
| Health checks | Actuator, custom endpoints | Liveness invariants (future: generated endpoints) |
| Process restart | Kubernetes pod restart | OTP supervisor (millisecond restart) |

## The count

**Eliminated by Vor + BEAM: 19 tools/concerns**

1. Separate design specification
2. External design verification tooling
3. External chaos testing infrastructure
4. External contract tests
5. Docker containers
6. Kubernetes orchestration
7. Container registry
8. Service mesh
9. Inter-service load balancers
10. External message queue
11. Inter-service serialization
12. Build tool complexity (Maven/Gradle)
13. Manual concurrency primitives
14. Telemetry instrumentation code
15. External input validation framework
16. External static analysis
17. Rolling deploy infrastructure
18. Secrets-in-logs prevention tooling
19. Helm charts

**Still needed: 8 concerns**

1. Infrastructure provisioning (Terraform or equivalent)
2. Reverse proxy for external HTTP (nginx/Caddy)
3. Telemetry backend (Prometheus/Grafana)
4. CI/CD pipeline (GitHub Actions or equivalent)
5. Load testing tools
6. Secrets management
7. Log aggregation at scale
8. Deployment orchestration for auto-scaling (the big gap)

The 19 eliminated are application-level concerns. The 8 remaining are infrastructure-level. Vor eliminates the application complexity. The infrastructure layer is where the gap is.

## Compared to other BEAM languages

Erlang and Elixir already eliminate many items from the typical stack — process isolation, supervision, distribution, message passing are all BEAM features. What they don't have:

| Concern | Erlang/Elixir | Vor |
|---|---|---|
| State machine verification | Manual testing | Proven at compile time |
| Protocol compatibility | Runtime errors | Checked at compile time |
| Multi-agent model checking | Not available | `mix vor.check` |
| Chaos simulation | Not built in | `mix vor.simulate` |
| Auto-generated telemetry | Manual instrumentation | Compiler-generated |
| Input constraints | Manual guards | Protocol `where` clauses |
| Sensitive data handling | Manual | `sensitive` annotation |
| Invariant-based recovery | Manual | Declared resilience handlers |

Vor doesn't replace OTP — it compiles to OTP. It adds the verification, observability, and testing layers that OTP doesn't provide.

## Compared to verification tools

| | TLA+ / TLC | Stateright | Vor |
|---|---|---|---|
| Artifact model | Separate spec | Library trait | Compiler IR (same artifact) |
| Execution | Spec only | Rust binary | BEAM binary |
| Drift risk | Spec drifts from impl | Trait can diverge from handler | Impossible (shared IR) |
| Observability | None | None | Auto-generated telemetry |
| Chaos testing | None | None | Built-in `mix vor.simulate` |
| Input constraints | Not applicable | Manual | Protocol `where` clauses |
| State space | Large (mature) | Large (Rust speed) | Bounded (small protocols) |

TLA+ and Stateright are stronger model checkers. Vor's advantage is that verification, observability, and chaos testing come from the same source file that produces the production binary.

## The honest risks

**Expressiveness limits.** Vor's expression language is simpler than Erlang, Elixir, or Gleam. All five examples are expressible natively, but complex data operations require Gleam externs.

**Bounded verification.** The model checker uses integer saturation and queue bounds. Large systems may exceed tractable bounds.

**Single-node chaos.** `mix vor.simulate` runs on one BEAM node with proxied partitions. Not the same as real multi-node network failures.

**Deployment gap.** No open-source BEAM-native auto-scaling exists. You use Fly.io (proprietary), tolerate Kubernetes (fights the BEAM), or manage VMs manually.

**Small ecosystem.** VorDB is the first real consumer. The language is unproven at scale.

---

*vorlang.org  ·  BEAM/OTP  ·  MIT License  ·  394+ tests*
