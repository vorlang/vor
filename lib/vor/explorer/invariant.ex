defmodule Vor.Explorer.Invariant do
  @moduledoc """
  Evaluates system-level safety invariants against a product state.

  Phase 1 supports the restricted form:

      never(count(agents where FIELD == :VALUE) OP N)

  where OP is one of `>`, `>=`, `==`, `<`, `<=`. The internal representation
  uses one tag per operator (`:count_gt`, `:count_gte`, `:count_eq`,
  `:count_lt`, `:count_lte`) so the evaluator stays branch-free.
  """

  alias Vor.Explorer.ProductState
  alias Vor.IR

  @doc """
  Returns `:ok` if the invariant holds in `ps`, or `{:violation, name}` if it
  is violated.
  """
  def check(%ProductState{} = ps, %IR.SystemInvariant{name: name, body: body}) do
    if evaluate(ps, body) do
      :ok
    else
      {:violation, name}
    end
  end

  # `never(condition)` — invariant holds when the condition is false.
  defp evaluate(ps, {:never, condition}), do: not evaluate_condition(ps, condition)

  defp evaluate_condition(ps, {:count_gt, agents_where, threshold}),
    do: count_matching(ps, agents_where) > threshold

  defp evaluate_condition(ps, {:count_gte, agents_where, threshold}),
    do: count_matching(ps, agents_where) >= threshold

  defp evaluate_condition(ps, {:count_eq, agents_where, threshold}),
    do: count_matching(ps, agents_where) == threshold

  defp evaluate_condition(ps, {:count_lt, agents_where, threshold}),
    do: count_matching(ps, agents_where) < threshold

  defp evaluate_condition(ps, {:count_lte, agents_where, threshold}),
    do: count_matching(ps, agents_where) <= threshold

  defp count_matching(%ProductState{agents: agents}, {:agents_where, field, op, value}) do
    agents
    |> Map.values()
    |> Enum.count(fn agent_state ->
      compare(Map.get(agent_state, field), op, value)
    end)
  end

  defp compare(actual, :==, expected), do: actual == expected
  defp compare(actual, :!=, expected), do: actual != expected
end
