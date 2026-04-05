defmodule Vor.Analysis.TypeChecker do
  @moduledoc """
  Lightweight type tracking through handler bodies.
  Detects guaranteed crashes (map op on integer, arithmetic on map, etc.)
  without requiring type annotations from the developer.
  """

  alias Vor.IR

  @doc """
  Run type checking on all handlers. Returns {:ok, warnings} or {:error, errors}.
  Only :error level diagnostics block compilation.
  """
  def check(%IR.Agent{} = agent) do
    env = init_env(agent)

    diagnostics =
      agent.handlers
      |> Enum.flat_map(fn handler ->
        handler_env = add_pattern_vars(env, handler.pattern)
        check_actions(handler.actions, handler_env)
      end)

    # Also check init handler if present
    init_diagnostics = case agent.init_handler do
      nil -> []
      handler -> check_actions(handler.actions, env)
    end

    all = diagnostics ++ init_diagnostics
    errors = Enum.filter(all, fn {level, _} -> level == :error end)

    case errors do
      [] -> {:ok, all}
      _ -> {:error, %{type: :type_error, diagnostics: errors}}
    end
  end

  defp init_env(agent) do
    bindings = %{}

    # State fields
    bindings = Enum.reduce(agent.data_fields || [], bindings, fn field, acc ->
      type = case field.type do
        :integer -> :integer
        :atom -> :atom
        :map -> :map
        :list -> :list
        :binary -> :binary
        _ -> :term
      end
      Map.put(acc, field.name, type)
    end)

    # Enum state fields → atom
    bindings = Enum.reduce(agent.state_fields || [], bindings, fn field, acc ->
      Map.put(acc, field.name, :atom)
    end)

    # Parameters
    bindings = Enum.reduce(agent.params || [], bindings, fn {name, type}, acc ->
      vor_type = case type do
        :integer -> :integer
        :atom -> :atom
        :binary -> :binary
        :map -> :map
        :list -> :list
        _ -> :term
      end
      Map.put(acc, name, vor_type)
    end)

    bindings
  end

  defp add_pattern_vars(env, %IR.MatchPattern{bindings: bindings}) do
    Enum.reduce(bindings, env, fn
      %IR.Binding{name: {:literal, _}}, acc -> acc
      %IR.Binding{name: name}, acc -> Map.put(acc, name, :term)
    end)
  end

  defp check_actions(actions, env) do
    {diagnostics, _final_env} = Enum.reduce(actions, {[], env}, fn action, {diags, e} ->
      {new_diags, new_env} = check_action(action, e)
      {diags ++ new_diags, new_env}
    end)
    diagnostics
  end

  defp check_action(%IR.Action{type: :var_binding, data: %{name: name, expr: expr}}, env) do
    {diags, result_type} = check_expr(expr, env)
    {diags, Map.put(env, name, result_type)}
  end

  defp check_action(%IR.Action{type: :extern_call, data: %{bind: bind, module: mod}}, env) when not is_nil(bind) do
    result_type = case mod do
      {:gleam_mod, _} -> :term  # TODO: use Gleam interface return type when available
      _ -> :term
    end
    {[], Map.put(env, bind, result_type)}
  end

  defp check_action(%IR.Action{type: :transition, data: %{field: field, value: value}}, env) do
    {diags, value_type} = check_value_type(value, env)
    field_type = Map.get(env, field, :term)

    transition_diags = case {field_type, value_type} do
      {:term, _} -> []
      {_, :term} -> []
      {same, same} -> []
      {expected, actual} ->
        [{:warning, "Transition #{field}: assigning #{actual} to #{expected} field"}]
    end

    {diags ++ transition_diags, env}
  end

  defp check_action(%IR.Action{type: :conditional, data: %IR.ConditionalAction{then_actions: ta, else_actions: ea}}, env) do
    then_diags = check_actions(ta, env)
    else_diags = check_actions(ea, env)
    {then_diags ++ else_diags, env}
  end

  defp check_action(_, env), do: {[], env}

  # Check an expression and return {diagnostics, result_type}
  defp check_expr({:arith, _op, left, right}, env) do
    {ld, lt} = check_value_type(left, env)
    {rd, rt} = check_value_type(right, env)
    arith_diags = check_type_compat(lt, :integer, "arithmetic operand") ++
                  check_type_compat(rt, :integer, "arithmetic operand")
    {ld ++ rd ++ arith_diags, :integer}
  end

  defp check_expr({:map_op, op, args}, env) when op in [:map_get] do
    case args do
      [map_ref | _] ->
        {diags, mt} = check_value_type(map_ref, env)
        {diags ++ check_type_compat(mt, :map, "#{op} first argument"), :term}
      _ -> {[], :term}
    end
  end

  defp check_expr({:map_op, op, args}, env) when op in [:map_put, :map_delete] do
    case args do
      [map_ref | _] ->
        {diags, mt} = check_value_type(map_ref, env)
        {diags ++ check_type_compat(mt, :map, "#{op} first argument"), :map}
      _ -> {[], :map}
    end
  end

  defp check_expr({:map_op, op, args}, env) when op in [:map_merge] do
    case args do
      [m1, m2 | _] ->
        {d1, t1} = check_value_type(m1, env)
        {d2, t2} = check_value_type(m2, env)
        {d1 ++ d2 ++ check_type_compat(t1, :map, "#{op} first argument") ++
         check_type_compat(t2, :map, "#{op} second argument"), :map}
      _ -> {[], :map}
    end
  end

  defp check_expr({:map_op, op, args}, env) when op in [:map_size, :map_sum] do
    case args do
      [map_ref | _] ->
        {diags, mt} = check_value_type(map_ref, env)
        {diags ++ check_type_compat(mt, :map, "#{op} argument"), :integer}
      _ -> {[], :integer}
    end
  end

  defp check_expr({:map_op, :map_has, args}, env) do
    case args do
      [map_ref | _] ->
        {diags, mt} = check_value_type(map_ref, env)
        {diags ++ check_type_compat(mt, :map, "map_has argument"), :atom}
      _ -> {[], :atom}
    end
  end

  defp check_expr({:map_op, op, args}, env) when op in [:list_head] do
    case args do
      [list_ref | _] ->
        {diags, lt} = check_value_type(list_ref, env)
        {diags ++ check_type_compat(lt, :list, "#{op} argument"), :term}
      _ -> {[], :term}
    end
  end

  defp check_expr({:map_op, op, args}, env) when op in [:list_tail, :list_append, :list_prepend] do
    case args do
      [list_ref | _] ->
        {diags, lt} = check_value_type(list_ref, env)
        {diags ++ check_type_compat(lt, :list, "#{op} argument"), :list}
      _ -> {[], :list}
    end
  end

  defp check_expr({:map_op, op, args}, env) when op in [:list_length] do
    case args do
      [list_ref | _] ->
        {diags, lt} = check_value_type(list_ref, env)
        {diags ++ check_type_compat(lt, :list, "#{op} argument"), :integer}
      _ -> {[], :integer}
    end
  end

  defp check_expr({:map_op, :list_empty, args}, env) do
    case args do
      [list_ref | _] ->
        {diags, lt} = check_value_type(list_ref, env)
        {diags ++ check_type_compat(lt, :list, "list_empty argument"), :atom}
      _ -> {[], :atom}
    end
  end

  defp check_expr({:minmax, _op, left, right}, env) do
    {ld, lt} = check_value_type(left, env)
    {rd, rt} = check_value_type(right, env)
    {ld ++ rd ++ check_type_compat(lt, :integer, "min/max operand") ++
     check_type_compat(rt, :integer, "min/max operand"), :integer}
  end

  defp check_expr(_, _env), do: {[], :term}

  # Get the type of a value reference
  defp check_value_type({:param, name}, env), do: {[], Map.get(env, name, :term)}
  defp check_value_type({:bound_var, name}, env), do: {[], Map.get(env, name, :term)}
  defp check_value_type({:integer, _}, _env), do: {[], :integer}
  defp check_value_type({:atom, _}, _env), do: {[], :atom}
  defp check_value_type({:list, _}, _env), do: {[], :list}
  defp check_value_type({:arith, _, _, _} = expr, env), do: check_expr(expr, env)
  defp check_value_type({:map_op, _, _} = expr, env), do: check_expr(expr, env)
  defp check_value_type({:minmax, _, _, _} = expr, env), do: check_expr(expr, env)
  defp check_value_type(_, _env), do: {[], :term}

  # Check if actual type is compatible with expected. Only error on guaranteed mismatch.
  defp check_type_compat(actual, expected, context) do
    cond do
      actual == expected -> []
      actual == :term -> []
      expected == :term -> []
      true -> [{:error, "Type error in #{context}: expected #{expected}, got #{actual}"}]
    end
  end
end
