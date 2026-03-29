# Worked Example: Rate-Limited API Gateway

This example stresses the model with state, concurrency, temporal invariants, failure handling, and backpressure.

```vor
agent ApiGateway do

  %% --- KNOWLEDGE ---
  relation rate_limit(client: client_id, max_requests: int, window: duration) do
    fact(client: :default, max_requests: 100, window: 60.s)
  end

  %% --- STATE ---
  %% Request counts per client, tracked over sliding windows.
  %% State is mutable within an agent — relations handle knowledge,
  %% state handles temporal reality.
  state request_counts: map(client_id, list(timestamp))

  %% --- PROTOCOL ---
  protocol do
    accepts {:request, client: client_id, payload: term}
    emits   {:response, status: status_code, body: term}
    emits   {:rejected, client: client_id, reason: term}

    %% Backpressure: if queue depth exceeds threshold,
    %% signal upstream to slow down
    backpressure when queue_depth > 500 do
      emit {:backpressure, load: queue_depth}
    end
  end

  %% --- BEHAVIOR ---
  on {:request, client: C, payload: P} do
    solve rate_limit(client: C, max_requests: Max, window: W) do
      recent = count_recent(request_counts[C], within: W)
      if recent < Max do
        record_request(C)
        forward_with_retry(P, to: :backend, max_retries: 3) do
          on {:ok, result}    -> emit {:response, status: 200, body: result}
          on {:error, reason} -> emit {:response, status: 502, body: reason}
          on :timeout         -> emit {:response, status: 504, body: "upstream timeout"}
        end
      else
        emit {:rejected, client: C, reason: :rate_exceeded}
      end
    end
  end

  %% --- INVARIANTS ---

  %% PROVEN (compiler-verified): rate limit logic is correct
  invariant "rate limit respected" proven do
    forall C: client_id, W: duration, Max: int
      where rate_limit(client: C, max_requests: Max, window: W)
      -> count(forwarded_requests(client: C), within: W) <= Max
  end

  %% MONITORED (runtime): liveness guarantee
  invariant "responsive" monitored do
    always(
      received({:request, _})
        implies eventually(
          emitted({:response, _}) or emitted({:rejected, _}),
          within: 5.s
        )
    )
  end

  %% MONITORED (runtime): circuit breaker pattern
  invariant "backend health" monitored do
    when count(emitted({:response, status: 502, _}), within: 30.s) > 10 do
      trigger :circuit_open
    end
  end

  %% --- RESILIENCE ---
  resilience do
    on_invariant_violation("responsive") -> log_warning, continue
    on_invariant_violation("backend health") ->
      stop_forwarding for 30.s,  %% circuit breaker opens
      emit {:response, status: 503, body: "service unavailable"}
    on_crash -> restart_with_state(request_counts)  %% preserve rate limit state
  end

  %% --- SYNTHESIS OBLIGATION ---
  %% The AI must implement the sliding window counter.
  %% Human specifies WHAT; AI decides HOW.
  synthesize count_recent(timestamps, within: window) do
    property: returns count of timestamps within window of now
    property: O(1) amortized time complexity
    property: memory bounded by max_requests * 2
    %% AI might use a ring buffer, a sorted list with pruning,
    %% or a hierarchical timing wheel — whatever satisfies the bounds.
  end

end
```

## What this demonstrates

**State and knowledge are separate.** `rate_limit` is a relation (queryable, potentially bidirectional — "which clients have a 100-request limit?"). `request_counts` is mutable state that changes over time. Vor doesn't pretend everything is a relation.

**Guarantee tiers are explicit.** The rate limit correctness invariant is tagged `proven` — the compiler must verify it. The responsiveness and health invariants are tagged `monitored` — they're checked at runtime with defined responses when violated.

**Failure has semantics.** The retry logic, circuit breaker, and resilience block define what happens when the backend fails, when the circuit opens, and when the agent itself crashes. These aren't afterthoughts — they're part of the spec.

**Synthesis is bounded.** The `count_recent` obligation includes performance bounds (O(1) amortized, memory-bounded). The AI can't produce a naive implementation that technically satisfies correctness but blows up memory. If the AI can't meet the bounds, synthesis fails explicitly.

**Backpressure is declared.** The protocol includes a `backpressure` clause — not something the developer handles in ad-hoc code, but a first-class part of the agent's contract.

**Escape hatches exist.** If the synthesized `count_recent` isn't good enough, or if the backend integration requires raw socket handling, the developer can drop to Erlang/Elixir for that specific component. The rest of the agent remains in Vor.
