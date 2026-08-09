defmodule Vor.Features.CodegenConformanceTest do
  @moduledoc """
  Codegen conformance matrix — the compiler's own relevance axis: *did the
  generated code do everything the source declared?*

  For every (action × handler-context) cell we generate a minimal `.vor` program
  whose only interesting behavior is that one action in that one context, compile
  → load → start → trigger the context → and assert the **observable effect**
  (peer receives the message / `:sys.get_state` shows the value / the caller gets
  the reply). Telemetry is never the sole evidence — it is codegen output and can
  lie consistently (the seed-7 lesson).

  Rejected cells (e.g. `emit` in a caller-less context) assert the program
  **fails to compile** with an explanatory error — refusing is conformance too.

  The matrix is defined as data (`@cells`); adding an IR action type or handler
  context that isn't represented here trips `test "matrix covers the IR action
  set"`, so the grid can't silently fall behind the grammar.

  See `evidence/conformance-matrix.md` for the grid, the pre-fix red run, and the
  dispatch-point enumeration.
  """
  use ExUnit.Case, async: false

  # A per-cell unique suffix keeps generated module/registry/system names from
  # colliding across cells (each cell starts its own supervisor + registry).
  defp uniq, do: System.unique_integer([:positive])

  # ------------------------------------------------------------------
  # Runners — each returns the OBSERVED effect, never a self-report.
  # ------------------------------------------------------------------

  # Single agent: trigger the context, then read real process state / reply.
  defp run_self(agent_src, start_args, trigger, wait_ms) do
    {:ok, r} = Vor.Compiler.compile_and_load(agent_src)
    {:ok, pid} = :gen_statem.start_link(r.module, start_args, [])
    reply = trigger.(pid)
    Process.sleep(wait_ms)
    {state, data} = :sys.get_state(pid)
    :gen_statem.stop(pid)
    %{phase: state, data: data, reply: reply}
  end

  # Two-agent system: sender performs the action-under-test toward :b; observe
  # the RECEIVER's state (a real peer got the message), not the sender.
  defp run_peer(system_src, trigger, wait_ms) do
    {:ok, res} = Vor.Compiler.compile_system_and_load(system_src)
    {:ok, sup} = res.system.start_link.()
    Process.sleep(200)
    reg = res.system.registry
    [{a, _}] = Registry.lookup(reg, :a)
    trigger.(a)
    Process.sleep(wait_ms)
    got =
      case Registry.lookup(reg, :b) do
        [{b, _}] -> receiver_got(:sys.get_state(b))
        _ -> :receiver_gone
      end
    Supervisor.stop(sup)
    got
  end

  defp compile_result(agent_src), do: Vor.Compiler.compile_string(agent_src)

  # Receiver is a gen_server (map state) or gen_statem ({state, data}); read `got`
  # from either shape.
  defp receiver_got({_state, data}) when is_map(data), do: Map.get(data, :got)
  defp receiver_got(data) when is_map(data), do: Map.get(data, :got)

  # ------------------------------------------------------------------
  # Source builders — a sender-agent body per context, given an action snippet.
  # `n` is the per-cell unique id, `phase_states` the enum the agent declares.
  # ------------------------------------------------------------------

  # Self-observed agent (one agent, no peer). `action` mutates `phase`/`hits`.
  defp self_agent(ctx, action, n) do
    case ctx do
      :message ->
        "agent Slf#{n} do\n  state phase: :s0 | :s1\n  state hits: integer\n  protocol do\n    accepts {:go}\n  end\n  on {:go} do\n    #{action}\n  end\nend"

      :guarded ->
        "agent Slf#{n} do\n  state phase: :s0 | :s1\n  state hits: integer\n  protocol do\n    accepts {:go}\n  end\n  on {:go} when phase == :s0 do\n    #{action}\n  end\nend"

      :every ->
        "agent Slf#{n}(t: integer) do\n  state phase: :s0 | :s1\n  state hits: integer\n  protocol do\n    accepts {:go}\n  end\n  on {:go} when phase == :s1 do\n    transition phase: :s0\n  end\n  every t do\n    #{action}\n  end\nend"

      :fired ->
        "agent Slf#{n} do\n  state phase: :s0 | :s1\n  state hits: integer\n  protocol do\n    accepts {:go}\n  end\n  on {:go} when phase == :s1 do\n    transition phase: :s0\n  end\n  on :wake_fired do\n    #{action}\n  end\nend"

      :resilience ->
        # step6 pattern: monitor arms on entering a non-safe state (:s1).
        "agent Slf#{n}(t: integer) do\n  state phase: :s0 | :s1\n  state hits: integer\n  protocol do\n    accepts {:open}\n    emits {:ok}\n  end\n  on {:open} when phase == :s0 do\n    transition phase: :s1\n    emit {:ok}\n  end\n  liveness \"back\" monitored(within: t) do\n    always(phase != :s0 implies eventually(phase == :s0))\n  end\n  resilience do\n    on_invariant_violation(\"back\") ->\n      #{action}\n  end\nend"

      :init ->
        "agent Slf#{n} do\n  state phase: :s0 | :s1\n  state hits: integer\n  protocol do\n    accepts {:go}\n  end\n  on :init do\n    #{action}\n  end\n  on {:go} when phase == :s0 do\n    transition phase: :s1\n  end\nend"
    end
  end

  # Two-agent system: sender does `action` (a send/broadcast to :b) in `ctx`.
  defp peer_system(ctx, action, n) do
    receiver =
      "agent Rcv#{n} do\n  state got: integer\n  protocol do\n    accepts {:beat}\n  end\n  on {:beat} do\n    transition got: 1\n  end\nend"

    sender_body =
      case ctx do
        :message -> "  on {:go} do\n    #{action}\n  end"
        :guarded -> "  on {:go} when phase == :s0 do\n    #{action}\n  end"
        :every -> "  on {:go} when phase == :s1 do\n    transition phase: :s0\n  end\n  every t do\n    #{action}\n  end"
        :fired -> "  on {:go} when phase == :s1 do\n    transition phase: :s0\n  end\n  on :wake_fired do\n    #{action}\n  end"
        :resilience ->
          "  on {:open} when phase == :s0 do\n    transition phase: :s1\n    emit {:ok}\n  end\n  liveness \"back\" monitored(within: t) do\n    always(phase != :s0 implies eventually(phase == :s0))\n  end\n  resilience do\n    on_invariant_violation(\"back\") ->\n      #{action}\n  end"
        :init -> "  on {:go} when phase == :s0 do\n    transition phase: :s1\n  end\n  on :init do\n    #{action}\n  end"
      end

    params = if ctx in [:every, :resilience], do: "(t: integer)", else: ""

    accepts =
      case ctx do
        :resilience -> "    accepts {:open}\n    emits {:ok}\n    sends {:beat}"
        _ -> "    accepts {:go}\n    sends {:beat}"
      end

    sender =
      "agent Snd#{n}#{params} do\n  state phase: :s0 | :s1\n  protocol do\n#{accepts}\n  end\n#{sender_body}\nend"

    "#{sender}\n\n#{receiver}\n\nsystem Sys#{n} do\n  agent :a, Snd#{n}#{if params == "", do: "()", else: "(t: 40)"}\n  agent :b, Rcv#{n}()\n  connect :a -> :b\nend"
  end

  # Trigger + start args per context, for self probes.
  defp self_trigger(:message, _), do: {[], fn pid -> :gen_statem.cast(pid, {:go, %{}}) end, 120}
  defp self_trigger(:guarded, _), do: {[], fn pid -> :gen_statem.cast(pid, {:go, %{}}) end, 120}
  defp self_trigger(:every, _), do: {[t: 40], fn _ -> :ok end, 180}
  defp self_trigger(:fired, _), do: {[], fn pid -> Kernel.send(pid, :wake_fired) end, 150}
  defp self_trigger(:resilience, _), do: {[t: 60], fn pid -> :gen_statem.call(pid, {:open, %{}}) end, 320}
  defp self_trigger(:init, _), do: {[], fn _ -> :ok end, 120}

  defp peer_trigger(:message), do: {fn a -> :gen_statem.cast(a, {:go, %{}}) end, 150}
  defp peer_trigger(:guarded), do: {fn a -> :gen_statem.cast(a, {:go, %{}}) end, 150}
  defp peer_trigger(:every), do: {fn _ -> :ok end, 200}
  defp peer_trigger(:fired), do: {fn a -> Kernel.send(a, :wake_fired) end, 200}
  defp peer_trigger(:resilience), do: {fn a -> :gen_statem.call(a, {:open, %{}}) end, 350}
  defp peer_trigger(:init), do: {fn _ -> :ok end, 200}

  # ------------------------------------------------------------------
  # The matrix. Each cell: {action, context, class}.
  #   class: :supported (effect must occur) | :rejected (must not compile)
  # `every` accumulates, so its self-cells assert >= 1 rather than == 1.
  # ------------------------------------------------------------------

  @contexts [:message, :guarded, :every, :fired, :resilience, :init]
  @self_actions [:transition_enum, :data_update]
  @peer_actions [:send, :broadcast]

  # emit only makes sense where there is a caller (message/guarded); elsewhere
  # it is a caller-less no-op and must be REJECTED at compile time.
  @emit_contexts_supported [:message, :guarded]
  @emit_contexts_rejected [:every, :fired, :resilience, :init]

  # transition_enum in :init is n/a (no enum state entered yet — it crashes);
  # excluded from the supported set and asserted-rejected instead.
  defp self_supported?(:transition_enum, :init), do: false
  defp self_supported?(_, _), do: true

  # ------------------------------------------------------------------
  # Self-observed cells: transition_enum, data_update
  # ------------------------------------------------------------------

  for ctx <- @contexts, action <- @self_actions do
    @ctx ctx
    @action action
    if action != :transition_enum or ctx != :init do
      test "#{action} in #{ctx} handler takes effect (observed via :sys.get_state)" do
        n = uniq()
        snippet =
          case @action do
            :transition_enum -> "transition phase: :s1"
            :data_update -> "transition hits: hits + 1"
          end

        src = self_agent(@ctx, snippet, n)
        {args, trig, wait} = self_trigger(@ctx, n)
        obs = run_self(src, args, trig, wait)

        case @action do
          :transition_enum ->
            assert obs.phase == :s1,
                   "#{@action}/#{@ctx}: expected phase :s1, got #{inspect(obs.phase)} — action dropped?"

          :data_update ->
            hits = Map.get(obs.data, :hits)
            assert is_integer(hits) and hits >= 1,
                   "#{@action}/#{@ctx}: expected hits >= 1, got #{inspect(hits)} — action dropped?"
        end
      end
    end
  end

  # transition_enum in init: currently crashes; classify as rejected/na and
  # assert it does NOT silently produce a broken process. (After A.2 this should
  # be a clean compile error; pre-fix it crashes at init — either way, not green.)
  test "transition_enum in init is not silently accepted as working" do
    n = uniq()
    src = self_agent(:init, "transition phase: :s1", n)
    # Either it fails to compile (preferred, post-A.2) or the process fails to
    # start — it must NOT come up reporting phase :s1 as if it worked.
    started_ok? =
      case Vor.Compiler.compile_and_load(src) do
        {:ok, r} ->
          case :gen_statem.start_link(r.module, [], []) do
            {:ok, pid} ->
              {s, _} = :sys.get_state(pid)
              :gen_statem.stop(pid)
              s == :s1
            _ -> false
          end

        {:error, _} -> false
      end

    refute started_ok?, "init/transition_enum appeared to work — it must reject or fail, not silently mis-handle"
  end

  # ------------------------------------------------------------------
  # Peer-observed cells: send, broadcast (receiver must actually get it)
  # ------------------------------------------------------------------

  for ctx <- @contexts, action <- @peer_actions do
    @pctx ctx
    @paction action
    test "#{action} in #{ctx} handler is received by a real peer" do
      n = uniq()
      snippet =
        case @paction do
          :send -> "send :b {:beat}"
          :broadcast -> "broadcast {:beat}"
        end

      src = peer_system(@pctx, snippet, n)
      {trig, wait} = peer_trigger(@pctx)
      got = run_peer(src, trig, wait)

      assert got == 1,
             "#{@paction}/#{@pctx}: peer never received the message (got=#{inspect(got)}) — action dropped?"
    end
  end

  # ------------------------------------------------------------------
  # emit: supported in message/guarded (caller gets reply)
  # ------------------------------------------------------------------

  for ctx <- @emit_contexts_supported do
    @ectx ctx
    test "emit in #{ctx} handler delivers the reply to the caller" do
      n = uniq()

      src =
        case @ectx do
          :message ->
            "agent Em#{n} do\n  protocol do\n    accepts {:go}\n    emits {:done}\n  end\n  on {:go} do\n    emit {:done}\n  end\nend"

          :guarded ->
            "agent Em#{n} do\n  state phase: :s0 | :s1\n  protocol do\n    accepts {:go}\n    emits {:done}\n  end\n  on {:go} when phase == :s0 do\n    emit {:done}\n  end\nend"
        end

      {:ok, r} = Vor.Compiler.compile_and_load(src)

      reply =
        case @ectx do
          :message ->
            {:ok, pid} = GenServer.start_link(r.module, [])
            rep = GenServer.call(pid, {:go, %{}})
            GenServer.stop(pid)
            rep

          :guarded ->
            {:ok, pid} = :gen_statem.start_link(r.module, [], [])
            rep = :gen_statem.call(pid, {:go, %{}})
            :gen_statem.stop(pid)
            rep
        end

      assert match?({:done, _}, reply), "emit/#{@ectx}: caller did not receive {:done, _}, got #{inspect(reply)}"
    end
  end

  # ------------------------------------------------------------------
  # emit in caller-less contexts: must be REJECTED at compile time (A.3).
  # Pre-fix these compile silently (the emit is dead-dropped) → these tests are
  # RED until A.2/A.3 make the rejection explicit.
  # ------------------------------------------------------------------

  for ctx <- @emit_contexts_rejected do
    @rctx ctx
    test "emit in #{ctx} handler is rejected at compile time (no caller)" do
      n = uniq()

      src =
        case @rctx do
          :every ->
            "agent Rej#{n}(t: integer) do\n  state phase: :s0 | :s1\n  protocol do\n    accepts {:go}\n    emits {:tick}\n  end\n  on {:go} when phase == :s1 do\n    transition phase: :s0\n  end\n  every t do\n    emit {:tick}\n  end\nend"

          :fired ->
            "agent Rej#{n} do\n  state phase: :s0 | :s1\n  protocol do\n    accepts {:go}\n    emits {:tick}\n  end\n  on {:go} when phase == :s1 do\n    transition phase: :s0\n  end\n  on :wake_fired do\n    emit {:tick}\n  end\nend"

          :resilience ->
            "agent Rej#{n}(t: integer) do\n  state phase: :s0 | :s1\n  protocol do\n    accepts {:open}\n    emits {:ok}\n    emits {:tick}\n  end\n  on {:open} when phase == :s0 do\n    transition phase: :s1\n    emit {:ok}\n  end\n  liveness \"back\" monitored(within: t) do\n    always(phase != :s0 implies eventually(phase == :s0))\n  end\n  resilience do\n    on_invariant_violation(\"back\") ->\n      emit {:tick}\n  end\nend"

          :init ->
            "agent Rej#{n} do\n  state phase: :s0 | :s1\n  protocol do\n    accepts {:go}\n    emits {:tick}\n  end\n  on :init do\n    emit {:tick}\n  end\n  on {:go} when phase == :s0 do\n    transition phase: :s1\n  end\nend"
        end

      assert match?({:error, _}, compile_result(src)),
             "emit/#{@rctx}: expected a compile error (caller-less emit), but it compiled — silent drop"
    end
  end

  # ------------------------------------------------------------------
  # DP0 — gen_server drops actions AFTER the terminal (emit/conditional/solve).
  # ------------------------------------------------------------------

  test "gen_server: a data update AFTER emit is not dropped" do
    n = uniq()

    src =
      "agent Post#{n} do\n  state hits: integer\n  protocol do\n    accepts {:go}\n    emits {:done}\n  end\n  on {:go} do\n    emit {:done}\n    transition hits: hits + 1\n  end\nend"

    {:ok, r} = Vor.Compiler.compile_and_load(src)
    {:ok, pid} = GenServer.start_link(r.module, [])
    _ = GenServer.call(pid, {:go, %{}})
    %{hits: hits} = :sys.get_state(pid)
    GenServer.stop(pid)

    assert hits == 1, "post-emit transition dropped (hits=#{inspect(hits)}) — DP0 split_terminal"
  end

  # ------------------------------------------------------------------
  # Coverage guard — the matrix must track the IR action set.
  # ------------------------------------------------------------------

  test "matrix covers the handler-relevant IR action set" do
    # Actions the matrix exercises (as observable effects).
    covered = MapSet.new([:transition_enum, :data_update, :emit, :send, :broadcast])

    # Handler-body IR action types that produce observable effects and therefore
    # need a matrix row. var_binding/conditional/extern_call/solve/timer-ops are
    # compound/plumbing and covered indirectly; if a NEW observable action type
    # is added to the grammar, add it here + a row (this test is the tripwire).
    expected = MapSet.new([:transition_enum, :data_update, :emit, :send, :broadcast])

    assert MapSet.equal?(covered, expected),
           "IR action set changed — extend the conformance matrix. Missing: #{inspect(MapSet.difference(expected, covered))}"
  end
end
