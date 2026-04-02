defmodule Vor.Solver do
  @moduledoc """
  Compile-time symbolic equation inverter for bidirectional relations.
  Handles linear arithmetic: +, -, *, /.
  """

  @doc """
  Invert an equation to solve for `target`.

  Input: `{:assign, lhs_field, expr_ast}` where expr references field names
  Output: `{:ok, {:assign, target, inverted_expr}}` or `{:error, reason}`

  Expression AST:
  - `{:ref, field_name}` — reference to a relation field
  - `{:add, left, right}` — addition
  - `{:sub, left, right}` — subtraction
  - `{:mul, left, right}` — multiplication
  - `{:div, left, right}` — division
  - integer or float literal
  """
  def invert({:assign, lhs, rhs}, target) do
    cond do
      target == lhs ->
        # Target is already on the left — this IS the forward equation
        {:ok, {:assign, target, rhs}}

      not contains_ref?(rhs, target) ->
        {:error, :variable_not_in_equation}

      count_refs(rhs, target) > 1 ->
        {:error, :non_linear}

      contains_ref?(rhs, lhs) ->
        {:error, :target_on_both_sides}

      true ->
        # Isolate target from rhs, building inverse using lhs as the known value
        case isolate(rhs, target, {:ref, lhs}) do
          {:ok, inverted_expr} -> {:ok, {:assign, target, inverted_expr}}
          {:error, _} = err -> err
        end
    end
  end

  @doc """
  Generate the expression AST for evaluating an equation forward.
  Given bound field values, compute the unbound field.
  """
  def forward_expr({:assign, _lhs, rhs}), do: rhs

  # --- Isolation algorithm ---

  # Isolate `target` from `expr`, accumulating inverse operations on `acc`.
  # `acc` starts as `{:ref, lhs}` (the other side of the equation).

  defp isolate({:ref, target}, target, acc), do: {:ok, acc}

  # target is in left of add: expr = left + right → left = expr - right
  defp isolate({:add, left, right}, target, acc) do
    if contains_ref?(left, target) do
      isolate(left, target, {:sub, acc, right})
    else
      isolate(right, target, {:sub, acc, left})
    end
  end

  # target is in left of sub: expr = left - right → left = expr + right
  defp isolate({:sub, left, right}, target, acc) do
    if contains_ref?(left, target) do
      isolate(left, target, {:add, acc, right})
    else
      # expr = left - right, target in right → right = left - expr
      isolate(right, target, {:sub, left, acc})
    end
  end

  # target is in left of mul: expr = left * right → left = expr / right
  defp isolate({:mul, left, right}, target, acc) do
    if contains_ref?(left, target) do
      isolate(left, target, {:div, acc, right})
    else
      isolate(right, target, {:div, acc, left})
    end
  end

  # target is in left of div: expr = left / right → left = expr * right
  defp isolate({:div, left, right}, target, acc) do
    if contains_ref?(left, target) do
      isolate(left, target, {:mul, acc, right})
    else
      # expr = left / right, target in right → right = left / expr
      isolate(right, target, {:div, left, acc})
    end
  end

  defp isolate(_, _, _), do: {:error, :cannot_isolate}

  # --- Helpers ---

  defp contains_ref?({:ref, name}, name), do: true
  defp contains_ref?({:ref, _}, _), do: false
  defp contains_ref?({op, left, right}, name) when op in [:add, :sub, :mul, :div] do
    contains_ref?(left, name) or contains_ref?(right, name)
  end
  defp contains_ref?(_, _), do: false

  defp count_refs({:ref, name}, name), do: 1
  defp count_refs({:ref, _}, _), do: 0
  defp count_refs({op, left, right}, name) when op in [:add, :sub, :mul, :div] do
    count_refs(left, name) + count_refs(right, name)
  end
  defp count_refs(_, _), do: 0

  @doc """
  Evaluate a solver expression AST given a map of bound field values.
  Used for testing.
  """
  def eval(expr, bindings) do
    case expr do
      {:ref, name} -> Map.fetch!(bindings, name)
      {:add, l, r} -> eval(l, bindings) + eval(r, bindings)
      {:sub, l, r} -> eval(l, bindings) - eval(r, bindings)
      {:mul, l, r} -> eval(l, bindings) * eval(r, bindings)
      {:div, l, r} -> div(eval(l, bindings), eval(r, bindings))
      n when is_number(n) -> n
    end
  end
end
