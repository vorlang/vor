defmodule Vor.Features.ValueVerificationTest do
  @moduledoc """
  F3 (fail-closed value verification) and F4 (explorer applies `on :init`),
  surfaced by usecases/01-inventory. Both are red→green regressions.

  F3 — the compile tier proves single-agent state-machine properties only. A
  `proven` value invariant it cannot discharge must be *refused*
  (`:unsupported_invariant`), never passed by omission — "never claim to have
  verified a property you never exercised." The refusal teaches: it routes the
  author to `mix vor.check` / `monitored`.

  F4 — the model checker's initial state must reflect `on :init`, matching what
  the runtime produces. The load-bearing check is model-vs-reality agreement.
  """
  use ExUnit.Case, async: false

  # A gen_server inventory (no enum state) with a `proven` value invariant.
  defp inventory(reserve_body) do
    """
    agent Inv(capacity: integer) do
      state available: integer
      state reserved: integer
      state total: integer

      protocol do
        accepts {:reserve, qty: integer}
        emits {:granted}
      end

      on :init do
        transition available: capacity
        transition total: capacity
      end

    #{reserve_body}

      safety "stock non-negative" proven do
        never(available < 0)
      end
    end
    """
  end

  @guarded """
    on {:reserve, qty: Q} do
      if Q <= available do
        transition available: available - Q
        transition reserved: reserved + Q
        emit {:granted}
      else
        emit {:granted}
      end
    end
  """

  # The mutation from usecases/01-inventory.md §A.3 — unconditional subtract,
  # which trivially reaches negative stock.
  @mutated """
    on {:reserve, qty: Q} do
      transition available: available - Q
      transition reserved: reserved + Q
      emit {:granted}
    end
  """

  # ------------------------------------------------------------------
  # F3 — fail closed
  # ------------------------------------------------------------------

  test "F3: the mutation does NOT compile as proven (the acceptance oracle)" do
    assert {:error, %{type: :unsupported_invariant}} =
             Vor.Compiler.compile_string(inventory(@mutated))
  end

  test "F3: an honest gen_server `proven` value invariant is refused, not fake-proven" do
    # Consistent with the gen_statem path, which already refuses an unverifiable
    # value body. The compile tier does not silently accept what it cannot verify.
    assert {:error, %{type: :unsupported_invariant}} =
             Vor.Compiler.compile_string(inventory(@guarded))
  end

  test "F3: the refusal teaches — routes to the system tier / vor.check" do
    {:error, %{message: msg, name: name}} = Vor.Compiler.compile_string(inventory(@guarded))
    assert name == "stock non-negative"
    assert msg =~ "mix vor.check"
    assert msg =~ "proven"
  end

  test "F3: a gen_statem value invariant is also refused (teaching message)" do
    src = """
    agent Counter do
      state phase: :a | :b
      state n: integer
      protocol do
        accepts {:dec}
        emits {:ok}
      end
      on {:dec} do
        transition n: n - 1
        emit {:ok}
      end
      safety "n non-negative" proven do
        never(n < 0)
      end
    end
    """

    assert {:error, %{type: :unsupported_invariant, message: msg}} =
             Vor.Compiler.compile_string(src)

    assert msg =~ "mix vor.check"
  end

  # ------------------------------------------------------------------
  # F4 — explorer applies `on :init`
  # ------------------------------------------------------------------

  # An inventory whose value invariant is at the system tier (so the whole thing
  # compiles under the F3 fix) — used to inspect the checker's initial state.
  @checkable """
  agent Inv(capacity: integer) do
    state available: integer
    state reserved: integer

    protocol do
      accepts {:reserve, qty: integer}
      emits {:granted}
    end

    on :init do
      transition available: capacity
    end

    on {:reserve, qty: Q} do
      transition available: available - Q
      transition reserved: reserved + Q
      emit {:granted}
    end
  end

  system W do
    agent :inv, Inv(capacity: 3)

    safety "trivially true" checked do
      never(exists A where A.reserved == 99)
    end
  end
  """

  defp checker_initial_agent_state(system_src, instance) do
    {:ok, res} = Vor.Compiler.compile_system(system_src)

    instance_irs =
      Enum.into(res.system_ir.agents, %{}, fn inst ->
        {inst.name, res.agents[inst.type_name].ir}
      end)

    Vor.Explorer.ProductState.initial(res.system_ir, instance_irs).agents[instance]
  end

  test "F4: the checker's initial state reflects `on :init`, not the type default" do
    state = checker_initial_agent_state(@checkable, :inv)
    assert state.available == 3, "expected on :init to seed available = capacity in the checker"
  end

  test "F4: model-vs-reality — checker initial state == runtime :sys.get_state (the guard)" do
    checker = checker_initial_agent_state(@checkable, :inv)

    agent_src = @checkable |> String.replace(~r/\nsystem W do.*/s, "\n")
    {:ok, r} = Vor.Compiler.compile_and_load(agent_src)
    {:ok, pid} = GenServer.start_link(r.module, capacity: 3)
    runtime = :sys.get_state(pid)
    GenServer.stop(pid)

    for field <- [:available, :reserved] do
      assert Map.get(checker, field) == Map.get(runtime, field),
             "model-vs-reality gap on #{field}: checker=#{inspect(Map.get(checker, field))} " <>
               "runtime=#{inspect(Map.get(runtime, field))}"
    end
  end
end
