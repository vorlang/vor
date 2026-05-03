defmodule Vor.Parser do
  @moduledoc """
  Recursive descent parser for Vor.
  Takes token list from Vor.Lexer and produces Vor.AST nodes.
  """

  alias Vor.AST

  def parse(tokens) do
    case parse_agent(tokens) do
      {:ok, ast, []} -> {:ok, ast}
      {:ok, _ast, rest} -> {:error, {:unexpected_tokens, rest}}
      {:error, _} = err -> err
    end
  end

  @doc """
  Parse a source with multiple agents and an optional system block.
  Returns `{:ok, %{agents: [agents], system: system | nil}}`.
  """
  def parse_multi(tokens) do
    parse_top_level(tokens, [], nil)
  end

  defp parse_top_level([], agents, system) do
    {:ok, %{agents: Enum.reverse(agents), system: system}}
  end

  defp parse_top_level([{:keyword, _, :agent} | _] = tokens, agents, system) do
    case parse_agent(tokens) do
      {:ok, agent, rest} -> parse_top_level(rest, [agent | agents], system)
      {:error, _} = err -> err
    end
  end

  defp parse_top_level([{:keyword, _, :system} | _] = tokens, agents, _system) do
    case parse_system(tokens) do
      {:ok, sys, rest} -> parse_top_level(rest, agents, sys)
      {:error, _} = err -> err
    end
  end

  defp parse_top_level([token | _], _agents, _system), do: {:error, {:unexpected_top_level, token}}

  # --- System block ---

  defp parse_system([{:keyword, meta, :system}, {:identifier, _, name}, {:keyword, _, :do} | rest]) do
    case parse_system_entries(rest, [], [], []) do
      {:ok, agents, connections, mixed, rest} ->
        {reqs, invariants} = split_requires(mixed)
        {:ok, %AST.System{name: name, agents: agents, connections: connections,
                           invariants: invariants, requires: reqs, meta: meta}, rest}
      {:ok, agents, connections, mixed, rest, chaos} ->
        {reqs, invariants} = split_requires(mixed)
        {:ok, %AST.System{name: name, agents: agents, connections: connections,
                           invariants: invariants, requires: reqs, chaos: chaos, meta: meta}, rest}
      {:error, _} = err -> err
    end
  end

  defp split_requires(mixed) do
    Enum.split_with(mixed, &match?(%AST.Requires{}, &1))
  end

  defp parse_system_entries([{:keyword, _, :end} | rest], agents, connections, invariants) do
    {:ok, Enum.reverse(agents), Enum.reverse(connections), Enum.reverse(invariants), rest}
  end

  # agent :name, Type(params)
  defp parse_system_entries([{:keyword, _, :agent}, {:atom, meta, name}, {:delimiter, _, :comma},
                              {:identifier, _, type}, {:delimiter, _, :open_paren} | rest], agents, connections, invariants) do
    case parse_system_params(rest) do
      {:ok, params, rest} ->
        instance = %AST.AgentInstance{name: name, type: type, params: params, meta: meta}
        parse_system_entries(rest, [instance | agents], connections, invariants)
      {:error, _} = err -> err
    end
  end

  # connect :from -> :to
  defp parse_system_entries([{:keyword, meta, :connect}, {:atom, _, from}, {:operator, _, :arrow}, {:atom, _, to} | rest], agents, connections, invariants) do
    conn = %AST.Connect{from: from, to: to, meta: meta}
    parse_system_entries(rest, agents, [conn | connections], invariants)
  end

  # safety "name" proven do never(count(agents where FIELD == :VALUE) OP N) end
  defp parse_system_entries([{:keyword, _, :safety} | _] = tokens, agents, connections, invariants) do
    case parse_system_safety(tokens) do
      {:ok, inv, rest} -> parse_system_entries(rest, agents, connections, [inv | invariants])
      {:error, _} = err -> err
    end
  end

  # liveness "name" proven do ... end — in system blocks
  defp parse_system_entries([{:keyword, _, :liveness} | _] = tokens, agents, connections, invariants) do
    case parse_liveness(tokens) do
      {:ok, liveness, rest} ->
        # Store as a SystemSafety-like struct with the liveness body tokens
        inv = %AST.SystemSafety{name: liveness.name, tier: liveness.tier, body: {:liveness_body, liveness.body}}
        parse_system_entries(rest, agents, connections, [inv | invariants])
      {:error, _} = err -> err
    end
  end

  # requires :app_name — OTP application
  defp parse_system_entries([{:keyword, _, :requires}, {:atom, _, app} | rest], agents, connections, invariants) do
    req = %AST.Requires{type: :application, target: String.to_atom(app), args: []}
    parse_system_entries(rest, agents, connections, [req | invariants])
  end

  # requires Module.Name — module with start_link
  defp parse_system_entries([{:keyword, _, :requires}, {:identifier, _, first} | rest], agents, connections, invariants) do
    {segments, rest} = collect_module_segments([first], rest)
    mod = Module.concat(Enum.map(segments, fn s -> if is_atom(s), do: s, else: String.to_atom("#{s}") end))
    req = %AST.Requires{type: :module, target: mod, args: []}
    parse_system_entries(rest, agents, connections, [req | invariants])
  end

  defp collect_module_segments(acc, [{:operator, _, :dot}, {:identifier, _, seg} | rest]) do
    collect_module_segments(acc ++ [seg], rest)
  end

  defp collect_module_segments(acc, rest), do: {acc, rest}

  # chaos do ... end
  defp parse_system_entries([{:identifier, _, :chaos}, {:keyword, _, :do} | rest], agents, connections, invariants) do
    case parse_chaos_items(rest, %AST.ChaosConfig{}) do
      {:ok, chaos, rest} -> parse_system_entries(rest, agents, connections, invariants, chaos)
      {:error, _} = err -> err
    end
  end

  defp parse_system_entries([token | _], _a, _c, _i), do: {:error, {:unexpected_in_system, token}}

  # When a chaos block was parsed, thread it through subsequent entries
  defp parse_system_entries([{:keyword, _, :end} | rest], agents, connections, invariants, chaos) do
    {:ok, Enum.reverse(agents), Enum.reverse(connections), Enum.reverse(invariants), rest, chaos}
  end

  defp parse_system_entries(tokens, agents, connections, invariants, chaos) do
    case parse_system_entries(tokens, agents, connections, invariants) do
      {:ok, a, c, i, rest} -> {:ok, a, c, i, rest, chaos}
      {:ok, a, c, i, rest, _} -> {:ok, a, c, i, rest, chaos}
      {:error, _} = err -> err
    end
  end

  defp parse_system_safety([{:keyword, meta, :safety}, {:string, _, name},
                            {:keyword, _, tier}, {:keyword, _, :do} | rest])
       when tier in [:proven, :checked, :monitored] do
    case parse_system_invariant_body(rest) do
      {:ok, body, [{:keyword, _, :end} | rest]} ->
        {:ok, %AST.SystemSafety{name: name, tier: tier, body: body, meta: meta}, rest}

      {:ok, _body, [token | _]} ->
        {:error, {:expected_end_of_system_invariant, token}}

      {:error, _} = err ->
        err
    end
  end

  defp parse_system_safety([token | _]),
    do: {:error, {:expected_system_safety, token}}

  # System invariant body parser. Phase 1 supported only `never(count(...))`.
  # Phase 3 also recognises:
  #
  #   * never(exists VAR, VAR where COND)
  #   * never(exists VAR where COND)
  #   * for_all agents, COND
  #   * never(NAMED_REF_BOOLEAN_EXPR)
  #
  # COND inside `exists` uses qualified references (`A.field`); inside
  # `for_all` references are unqualified; the never-named form uses
  # `agent_name.field` references.

  # never(count(agents where FIELD == :VALUE) OP N)
  defp parse_system_invariant_body([
         {:keyword, _, :never}, {:delimiter, _, :open_paren},
         {:identifier, _, :count}, {:delimiter, _, :open_paren},
         {:identifier, _, :agents}, {:keyword, _, :where},
         {:identifier, _, field}, {:operator, _, op_eq}, {:atom, _, value},
         {:delimiter, _, :close_paren}, {:operator, _, op}, {:integer, _, n},
         {:delimiter, _, :close_paren} | rest
       ])
       when op_eq in [:==, :!=] and op in [:>, :>=, :<, :<=, :==] do
    cmp = case op_eq do
      :== -> :==
      :!= -> :!=
    end

    field_atom = if is_atom(field), do: field, else: String.to_atom(field)
    value_atom = if is_atom(value), do: value, else: String.to_atom(value)
    count_node = {:agents_where, field_atom, cmp, value_atom}

    body =
      case op do
        :> -> {:never, {:count_gt, count_node, n}}
        :>= -> {:never, {:count_gte, count_node, n}}
        :== -> {:never, {:count_eq, count_node, n}}
        :< -> {:never, {:count_lt, count_node, n}}
        :<= -> {:never, {:count_lte, count_node, n}}
      end

    {:ok, body, rest}
  end

  # never(exists VAR_A, VAR_B where COND)
  defp parse_system_invariant_body([
         {:keyword, _, :never}, {:delimiter, _, :open_paren},
         {:identifier, _, :exists},
         {:identifier, _, var_a}, {:delimiter, _, :comma}, {:identifier, _, var_b},
         {:keyword, _, :where} | rest
       ]) do
    var_a_atom = to_ident_atom(var_a)
    var_b_atom = to_ident_atom(var_b)
    bindings = MapSet.new([var_a_atom, var_b_atom])

    case parse_invariant_condition(rest, {:exists, bindings}) do
      {:ok, cond_node, [{:delimiter, _, :close_paren} | rest]} ->
        {:ok, {:never, {:exists_pair, var_a_atom, var_b_atom, cond_node}}, rest}

      {:ok, _, [token | _]} ->
        {:error, {:expected_close_paren, token}}

      {:error, _} = err ->
        err
    end
  end

  # never(exists VAR where COND)
  defp parse_system_invariant_body([
         {:keyword, _, :never}, {:delimiter, _, :open_paren},
         {:identifier, _, :exists}, {:identifier, _, var}, {:keyword, _, :where} | rest
       ]) do
    var_atom = to_ident_atom(var)
    bindings = MapSet.new([var_atom])

    case parse_invariant_condition(rest, {:exists, bindings}) do
      {:ok, cond_node, [{:delimiter, _, :close_paren} | rest]} ->
        {:ok, {:never, {:exists_single, var_atom, cond_node}}, rest}

      {:ok, _, [token | _]} ->
        {:error, {:expected_close_paren, token}}

      {:error, _} = err ->
        err
    end
  end

  # for_all agents, COND
  defp parse_system_invariant_body([
         {:identifier, _, :for_all}, {:identifier, _, :agents}, {:delimiter, _, :comma} | rest
       ]) do
    case parse_invariant_condition(rest, :for_all) do
      {:ok, cond_node, rest} ->
        {:ok, {:for_all, cond_node}, rest}

      {:error, _} = err ->
        err
    end
  end

  # never(NAMED_REF_BOOLEAN_EXPR) — terms are `agent_name.field OP value`
  defp parse_system_invariant_body([
         {:keyword, _, :never}, {:delimiter, _, :open_paren} | rest
       ]) do
    case parse_invariant_condition(rest, :named) do
      {:ok, cond_node, [{:delimiter, _, :close_paren} | rest]} ->
        {:ok, {:never, cond_node}, rest}

      {:ok, _, [token | _]} ->
        {:error, {:expected_close_paren, token}}

      {:error, _} = err ->
        err
    end
  end

  defp parse_system_invariant_body([token | _]),
    do: {:error, {:unsupported_system_invariant, token}}

  defp parse_system_invariant_body([]),
    do: {:error, :unexpected_eof}

  # ----------------------------------------------------------------------
  # Phase-3 invariant condition parser
  # ----------------------------------------------------------------------
  #
  # Parses boolean expressions of the form
  #
  #     TERM (and TERM | or TERM)*
  #
  # where TERM is a comparison whose shape depends on `mode`:
  #
  #   * `:exists` — `VAR.field OP value` or `VAR.field OP VAR.field`
  #     (the `bindings` set restricts which identifiers count as quantifier
  #     vars; anything else is treated as a syntax error)
  #   * `:for_all` — unqualified `field OP value`
  #   * `:named` — `agent_name.field OP value`
  #
  # Supports right-associative chains. `and` binds tighter than `or` (the
  # parser collects an `and`-chain first, then folds `or`s on top).

  defp parse_invariant_condition(tokens, mode) do
    case parse_invariant_or(tokens, mode) do
      {:ok, _node, _rest} = ok -> ok
      {:error, _} = err -> err
    end
  end

  defp parse_invariant_or(tokens, mode) do
    with {:ok, left, rest} <- parse_invariant_and(tokens, mode) do
      case rest do
        [{:keyword, _, :or} | rest2] ->
          with {:ok, right, rest3} <- parse_invariant_or(rest2, mode) do
            {:ok, {:or, left, right}, rest3}
          end

        _ ->
          {:ok, left, rest}
      end
    end
  end

  defp parse_invariant_and(tokens, mode) do
    with {:ok, left, rest} <- parse_invariant_term(tokens, mode) do
      case rest do
        [{:keyword, _, :and} | rest2] ->
          with {:ok, right, rest3} <- parse_invariant_and(rest2, mode) do
            {:ok, {:and, left, right}, rest3}
          end

        _ ->
          {:ok, left, rest}
      end
    end
  end

  # exists/named ref: IDENT.IDENT OP …
  defp parse_invariant_term([{:identifier, _, ref}, {:operator, _, :dot}, {:identifier, _, field},
                             {:operator, _, op} | rest], mode)
       when op in [:==, :!=] do
    field_atom = to_ident_atom(field)
    ref_atom = to_ident_atom(ref)

    left =
      case mode do
        {:exists, _bindings} -> {:agent_field, ref_atom, field_atom}
        :named -> {:named_agent_field, ref_atom, field_atom}
        :for_all -> {:agent_field, ref_atom, field_atom}
      end

    parse_invariant_rhs(left, op, rest, mode)
  end

  # for_all unqualified: IDENT OP …
  defp parse_invariant_term([{:identifier, _, field}, {:operator, _, op} | rest], :for_all)
       when op in [:==, :!=] do
    left = {:field, to_ident_atom(field)}
    parse_invariant_rhs(left, op, rest, :for_all)
  end

  defp parse_invariant_term([token | _], _mode), do: {:error, {:unexpected_in_invariant, token}}
  defp parse_invariant_term([], _mode), do: {:error, :unexpected_eof}

  # Right-hand side of a comparison: atom, integer, or another VAR.field
  # ref (for cross-agent comparisons inside `exists`).
  defp parse_invariant_rhs(left, op, [{:atom, _, val} | rest], _mode) do
    {:ok, {op, left, to_ident_atom(val)}, rest}
  end

  defp parse_invariant_rhs(left, op, [{:integer, _, n} | rest], _mode) do
    {:ok, {op, left, n}, rest}
  end

  defp parse_invariant_rhs(left, op, [{:identifier, _, ref}, {:operator, _, :dot}, {:identifier, _, field} | rest], mode) do
    right =
      case mode do
        {:exists, _} -> {:agent_field, to_ident_atom(ref), to_ident_atom(field)}
        :named -> {:named_agent_field, to_ident_atom(ref), to_ident_atom(field)}
        :for_all -> {:agent_field, to_ident_atom(ref), to_ident_atom(field)}
      end

    {:ok, {op, left, right}, rest}
  end

  defp parse_invariant_rhs(_left, _op, [token | _], _mode),
    do: {:error, {:expected_invariant_rhs, token}}

  defp parse_invariant_rhs(_left, _op, [], _mode),
    do: {:error, :unexpected_eof}

  defp to_ident_atom(v) when is_atom(v), do: v
  defp to_ident_atom(v) when is_binary(v), do: String.to_atom(v)

  # ------------------------------------------------------------------
  # Protocol constraint expression parser (where clause on accepts)
  # Grammar: expr = term ((and|or) term)*
  #          term = IDENT OP (IDENT | INTEGER | ATOM)
  # ------------------------------------------------------------------

  defp parse_constraint_expr(tokens), do: parse_constraint_or(tokens)

  defp parse_constraint_or(tokens) do
    with {:ok, left, rest} <- parse_constraint_and(tokens) do
      case rest do
        [{:keyword, _, :or} | rest2] ->
          with {:ok, right, rest3} <- parse_constraint_or(rest2),
            do: {:ok, {:or, left, right}, rest3}
        _ -> {:ok, left, rest}
      end
    end
  end

  defp parse_constraint_and(tokens) do
    with {:ok, left, rest} <- parse_constraint_term(tokens) do
      case rest do
        [{:keyword, _, :and} | rest2] ->
          with {:ok, right, rest3} <- parse_constraint_and(rest2),
            do: {:ok, {:and, left, right}, rest3}
        _ -> {:ok, left, rest}
      end
    end
  end

  # IDENT OP IDENT (cross-field or field vs field)
  defp parse_constraint_term([{:identifier, _, left}, {:operator, _, op},
                               {:identifier, _, right} | rest])
       when op in [:>, :<, :>=, :<=, :==, :!=] do
    {:ok, {op, {:field, to_ident_atom(left)}, {:field, to_ident_atom(right)}}, rest}
  end

  # IDENT OP INTEGER
  defp parse_constraint_term([{:identifier, _, left}, {:operator, _, op},
                               {:integer, _, right} | rest])
       when op in [:>, :<, :>=, :<=, :==, :!=] do
    {:ok, {op, {:field, to_ident_atom(left)}, {:literal, right}}, rest}
  end

  # IDENT OP :ATOM
  defp parse_constraint_term([{:identifier, _, left}, {:operator, _, op},
                               {:atom, _, right} | rest])
       when op in [:>, :<, :>=, :<=, :==, :!=] do
    {:ok, {op, {:field, to_ident_atom(left)}, {:literal, to_ident_atom(right)}}, rest}
  end

  defp parse_constraint_term([token | _]), do: {:error, {:expected_constraint_term, token}}
  defp parse_constraint_term([]), do: {:error, :unexpected_eof}

  # ------------------------------------------------------------------
  # Chaos block parser
  # ------------------------------------------------------------------

  defp parse_chaos_items([{:keyword, _, :end} | rest], config) do
    {:ok, config, rest}
  end

  # duration 30s | duration 5m | duration 30000
  defp parse_chaos_items([{:identifier, _, :duration} | rest], config) do
    {ms, rest} = parse_chaos_duration(rest)
    parse_chaos_items(rest, %{config | duration_ms: ms})
  end

  # seed 42
  defp parse_chaos_items([{:identifier, _, :seed}, {:integer, _, n} | rest], config) do
    parse_chaos_items(rest, %{config | seed: n})
  end

  # kill every: MIN..MAXs
  defp parse_chaos_items([{:identifier, _, :kill}, {kw_or_id, _, :every}, {:delimiter, _, :colon} | rest], config)
       when kw_or_id in [:identifier, :keyword] do
    {range, rest} = parse_chaos_range(rest)
    parse_chaos_items(rest, %{config | kill: %{every: range}})
  end

  # partition duration: MIN..MAXs
  defp parse_chaos_items([{:identifier, _, :partition}, {:identifier, _, :duration}, {:delimiter, _, :colon} | rest], config) do
    {range, rest} = parse_chaos_range(rest)
    parse_chaos_items(rest, %{config | partition: %{duration: range}})
  end

  # delay by: MIN..MAXms
  defp parse_chaos_items([{:identifier, _, :delay}, {:identifier, _, :by}, {:delimiter, _, :colon} | rest], config) do
    {range, rest} = parse_chaos_range(rest)
    parse_chaos_items(rest, %{config | delay: %{by: range}})
  end

  # drop probability: N (integer percentage, e.g. 1 = 1%)
  defp parse_chaos_items([{:identifier, _, :drop}, {:identifier, _, :probability}, {:delimiter, _, :colon}, {:integer, _, n} | rest], config) do
    parse_chaos_items(rest, %{config | drop: %{probability: n / 100}})
  end

  # check every: Nms
  defp parse_chaos_items([{:identifier, _, :check}, {kw_or_id, _, :every}, {:delimiter, _, :colon} | rest], config)
       when kw_or_id in [:identifier, :keyword] do
    {ms, rest} = parse_chaos_duration(rest)
    parse_chaos_items(rest, %{config | check: %{every: ms}})
  end

  # workload rate: N
  defp parse_chaos_items([{:identifier, _, :workload}, {:identifier, _, :rate}, {:delimiter, _, :colon}, {:integer, _, rate} | rest], config) do
    parse_chaos_items(rest, %{config | workload: %{rate: rate}})
  end

  defp parse_chaos_items([token | _], _config) do
    {:error, {:unexpected_in_chaos, token}}
  end

  # Duration: INTEGER UNIT? (s, m, ms) or bare integer (ms)
  defp parse_chaos_duration([{:integer, _, n}, {:identifier, _, :s} | rest]), do: {n * 1000, rest}
  defp parse_chaos_duration([{:integer, _, n}, {:identifier, _, :m} | rest]), do: {n * 60_000, rest}
  defp parse_chaos_duration([{:integer, _, n}, {:identifier, _, :ms} | rest]), do: {n, rest}
  defp parse_chaos_duration([{:integer, _, n} | rest]), do: {n, rest}

  # Range: MIN..MAX UNIT?
  defp parse_chaos_range([{:integer, _, min}, {:operator, _, :range}, {:integer, _, max}, {:identifier, _, :s} | rest]) do
    {{min * 1000, max * 1000}, rest}
  end

  defp parse_chaos_range([{:integer, _, min}, {:operator, _, :range}, {:integer, _, max}, {:identifier, _, :ms} | rest]) do
    {{min, max}, rest}
  end

  defp parse_chaos_range([{:integer, _, min}, {:operator, _, :range}, {:integer, _, max} | rest]) do
    {{min, max}, rest}
  end

  # Parse system agent params: either empty () or key: value pairs
  defp parse_system_params([{:delimiter, _, :close_paren} | rest]), do: {:ok, [], rest}
  defp parse_system_params(tokens) do
    parse_system_param_fields(tokens, [])
  end

  defp parse_system_param_fields([{:delimiter, _, :close_paren} | rest], acc) do
    {:ok, Enum.reverse(acc), rest}
  end

  defp parse_system_param_fields([{:delimiter, _, :comma} | rest], acc) do
    parse_system_param_field(rest, acc)
  end

  defp parse_system_param_fields(tokens, []) do
    parse_system_param_field(tokens, [])
  end

  defp parse_system_param_field([{:identifier, _, name}, {:delimiter, _, :colon}, {:integer, _, value} | rest], acc) do
    parse_system_param_fields(rest, [{name, value} | acc])
  end

  defp parse_system_param_field([{:identifier, _, name}, {:delimiter, _, :colon}, {:atom, _, value} | rest], acc) do
    parse_system_param_fields(rest, [{name, {:atom, value}} | acc])
  end

  defp parse_system_param_field([{:identifier, _, name}, {:delimiter, _, :colon}, {:string, _, value} | rest], acc) do
    parse_system_param_fields(rest, [{name, value} | acc])
  end

  defp parse_system_param_field([token | _], _acc), do: {:error, {:expected_system_param, token}}

  # --- Agent ---

  # Parameterized: agent Name(param: type, ...) do
  defp parse_agent([{:keyword, meta, :agent}, {:identifier, _, name}, {:delimiter, _, :open_paren} | rest]) do
    case parse_typed_fields_paren(rest, []) do
      {:ok, params, [{:keyword, _, :do} | rest]} ->
        case parse_declarations(rest, []) do
          {:ok, body, rest} ->
            {:ok, %AST.Agent{name: name, params: params, body: body, meta: meta}, rest}
          {:error, _} = err -> err
        end
      {:ok, _, [token | _]} -> {:error, {:expected_do, token}}
      {:error, _} = err -> err
    end
  end

  # Non-parameterized: agent Name do
  defp parse_agent([{:keyword, meta, :agent}, {:identifier, _, name}, {:keyword, _, :do} | rest]) do
    case parse_declarations(rest, []) do
      {:ok, body, rest} ->
        {:ok, %AST.Agent{name: name, params: [], body: body, meta: meta}, rest}
      {:error, _} = err -> err
    end
  end

  defp parse_agent([token | _]), do: {:error, {:expected_agent, token}}
  defp parse_agent([]), do: {:error, :unexpected_eof}

  # --- Declarations ---

  defp parse_declarations([{:keyword, _, :end} | rest], acc) do
    {:ok, Enum.reverse(acc), rest}
  end

  defp parse_declarations([{:keyword, _, :protocol} | _] = tokens, acc) do
    case parse_protocol(tokens) do
      {:ok, proto, rest} -> parse_declarations(rest, [proto | acc])
      {:error, _} = err -> err
    end
  end

  defp parse_declarations([{:keyword, _, :on} | _] = tokens, acc) do
    case parse_handler(tokens) do
      {:ok, handler, rest} -> parse_declarations(rest, [handler | acc])
      {:error, _} = err -> err
    end
  end

  defp parse_declarations([{:keyword, _, :state} | _] = tokens, acc) do
    case parse_state_decl(tokens) do
      {:ok, state, rest} -> parse_declarations(rest, [state | acc])
      {:error, _} = err -> err
    end
  end

  defp parse_declarations([{:keyword, _, :relation} | _] = tokens, acc) do
    case parse_relation(tokens) do
      {:ok, relation, rest} -> parse_declarations(rest, [relation | acc])
      {:error, _} = err -> err
    end
  end

  defp parse_declarations([{:keyword, _, :invariant} | _] = tokens, acc) do
    case parse_invariant(tokens) do
      {:ok, inv, rest} -> parse_declarations(rest, [inv | acc])
      {:error, _} = err -> err
    end
  end

  defp parse_declarations([{:keyword, _, :safety} | _] = tokens, acc) do
    case parse_safety(tokens) do
      {:ok, safety, rest} -> parse_declarations(rest, [safety | acc])
      {:error, _} = err -> err
    end
  end

  defp parse_declarations([{:keyword, _, :liveness} | _] = tokens, acc) do
    case parse_liveness(tokens) do
      {:ok, liveness, rest} -> parse_declarations(rest, [liveness | acc])
      {:error, _} = err -> err
    end
  end

  defp parse_declarations([{:keyword, _, :resilience} | _] = tokens, acc) do
    case parse_resilience(tokens) do
      {:ok, resilience, rest} -> parse_declarations(rest, [resilience | acc])
      {:error, _} = err -> err
    end
  end

  defp parse_declarations([{:keyword, _, :every} | _] = tokens, acc) do
    case parse_every(tokens) do
      {:ok, every, rest} -> parse_declarations(rest, [every | acc])
      {:error, _} = err -> err
    end
  end

  defp parse_declarations([{:keyword, _, :extern} | _] = tokens, acc) do
    case parse_extern_block(tokens) do
      {:ok, extern, rest} -> parse_declarations(rest, [extern | acc])
      {:error, _} = err -> err
    end
  end

  defp parse_declarations([token | _], _acc), do: {:error, {:unexpected_token, token}}
  defp parse_declarations([], _acc), do: {:error, :unexpected_eof}

  # --- Protocol ---

  defp parse_protocol([{:keyword, meta, :protocol}, {:keyword, _, :do} | rest]) do
    case parse_protocol_entries(rest, [], [], []) do
      {:ok, accepts, emits, sends, rest} ->
        {:ok, %AST.Protocol{accepts: accepts, emits: emits, sends: sends, meta: meta}, rest}
      {:error, _} = err -> err
    end
  end

  defp parse_protocol_entries([{:keyword, _, :end} | rest], accepts, emits, sends) do
    {:ok, Enum.reverse(accepts), Enum.reverse(emits), Enum.reverse(sends), rest}
  end

  defp parse_protocol_entries([{:keyword, _, :accepts} | rest], accepts, emits, sends) do
    case parse_message_spec(rest) do
      {:ok, spec, [{:keyword, _, :where} | rest]} ->
        case parse_constraint_expr(rest) do
          {:ok, constraint, rest} ->
            parse_protocol_entries(rest, [%{spec | constraint: constraint} | accepts], emits, sends)
          {:error, _} = err -> err
        end
      {:ok, spec, rest} ->
        parse_protocol_entries(rest, [spec | accepts], emits, sends)
      {:error, _} = err -> err
    end
  end

  defp parse_protocol_entries([{:keyword, _, :emits} | rest], accepts, emits, sends) do
    case parse_message_spec(rest) do
      {:ok, spec, rest} -> parse_protocol_entries(rest, accepts, [spec | emits], sends)
      {:error, _} = err -> err
    end
  end

  defp parse_protocol_entries([{:keyword, _, :sends} | rest], accepts, emits, sends) do
    case parse_message_spec(rest) do
      {:ok, spec, rest} -> parse_protocol_entries(rest, accepts, emits, [spec | sends])
      {:error, _} = err -> err
    end
  end

  defp parse_protocol_entries([token | _], _a, _e, _s), do: {:error, {:unexpected_in_protocol, token}}
  defp parse_protocol_entries([], _a, _e, _s), do: {:error, :unexpected_eof}

  # --- Message Spec: {:tag, field1: type1, field2: type2} ---

  defp parse_message_spec([{:delimiter, _, :open_brace}, {:atom, _, tag} | rest]) do
    case parse_typed_fields(rest, []) do
      {:ok, fields, rest} ->
        {:ok, %AST.MessageSpec{tag: tag, fields: fields}, rest}
      {:error, _} = err -> err
    end
  end

  defp parse_message_spec([token | _]), do: {:error, {:expected_message_spec, token}}

  defp parse_typed_fields([{:delimiter, _, :close_brace} | rest], acc) do
    {:ok, Enum.reverse(acc), rest}
  end

  defp parse_typed_fields([{:delimiter, _, :comma} | rest], acc) do
    parse_typed_field(rest, acc)
  end

  defp parse_typed_fields(tokens, []) do
    parse_typed_field(tokens, [])
  end

  defp parse_typed_field([{:identifier, _, name}, {:delimiter, _, :colon}, {:identifier, _, type} | rest], acc) do
    parse_typed_fields(rest, [{name, type} | acc])
  end

  defp parse_typed_field([token | _], _acc), do: {:error, {:expected_field, token}}

  # --- Handler: on PATTERN [when GUARD] do BODY end ---

  # on :init do ... end — special init handler
  defp parse_handler([{:keyword, meta, :on}, {:atom, _, "init"}, {:keyword, _, :do} | rest]) do
    case parse_handler_body(rest, []) do
      {:ok, body, rest} ->
        {:ok, %AST.Handler{pattern: %AST.Pattern{tag: "init", bindings: []}, guard: nil, body: body, meta: meta}, rest}
      {:error, _} = err -> err
    end
  end

  defp parse_handler([{:keyword, meta, :on} | rest]) do
    case parse_pattern(rest) do
      {:ok, pattern, rest} ->
        {guard, rest} = parse_optional_guard(rest)
        case rest do
          [{:keyword, _, :do} | rest] ->
            case parse_handler_body(rest, []) do
              {:ok, body, rest} ->
                {:ok, %AST.Handler{pattern: pattern, guard: guard, body: body, meta: meta}, rest}
              {:error, _} = err -> err
            end
          [token | _] -> {:error, {:expected_do, token}}
          [] -> {:error, :unexpected_eof}
        end
      {:error, _} = err -> err
    end
  end

  # --- Pattern: {:tag, field1: Var1} or :atom ---

  defp parse_pattern([{:delimiter, _, :open_brace}, {:atom, _, tag} | rest]) do
    case parse_binding_fields(rest, []) do
      {:ok, bindings, rest} ->
        {:ok, %AST.Pattern{tag: tag, bindings: bindings}, rest}
      {:error, _} = err -> err
    end
  end

  defp parse_pattern([{:atom, _, tag} | rest]) do
    {:ok, %AST.Pattern{tag: tag, bindings: []}, rest}
  end

  defp parse_pattern([token | _]), do: {:error, {:expected_pattern, token}}

  defp parse_binding_fields([{:delimiter, _, :close_brace} | rest], acc) do
    {:ok, Enum.reverse(acc), rest}
  end

  defp parse_binding_fields([{:delimiter, _, :comma} | rest], acc) do
    parse_binding_field(rest, acc)
  end

  defp parse_binding_fields(tokens, []) do
    parse_binding_field(tokens, [])
  end

  # field: _
  defp parse_binding_field([{:identifier, _, field}, {:delimiter, _, :colon}, {:identifier, _, :_} | rest], acc) do
    parse_binding_fields(rest, [{field, :wildcard} | acc])
  end

  # field: Var OP Var (arithmetic expression)
  defp parse_binding_field([{:identifier, _, field}, {:delimiter, _, :colon},
                             {:identifier, _, left}, {:operator, _, op},
                             {:identifier, _, right} | rest], acc)
       when op in [:minus, :plus, :star, :slash] do
    expr = %AST.ArithExpr{op: op, left: {:var, left}, right: {:var, right}}
    parse_binding_fields(rest, [{field, {:expr, expr}} | acc])
  end

  # field: Var OP Integer
  defp parse_binding_field([{:identifier, _, field}, {:delimiter, _, :colon},
                             {:identifier, _, left}, {:operator, _, op},
                             {:integer, _, right} | rest], acc)
       when op in [:minus, :plus, :star, :slash] do
    expr = %AST.ArithExpr{op: op, left: {:var, left}, right: {:integer, right}}
    parse_binding_fields(rest, [{field, {:expr, expr}} | acc])
  end

  # field: Integer OP Var (int-first arithmetic)
  defp parse_binding_field([{:identifier, _, field}, {:delimiter, _, :colon},
                             {:integer, _, left}, {:operator, _, op},
                             {:identifier, _, right} | rest], acc)
       when op in [:minus, :plus, :star, :slash] do
    expr = %AST.ArithExpr{op: op, left: {:integer, left}, right: {:var, right}}
    parse_binding_fields(rest, [{field, {:expr, expr}} | acc])
  end

  # field: Integer (integer literal in binding)
  defp parse_binding_field([{:identifier, _, field}, {:delimiter, _, :colon},
                             {:integer, _, value} | rest], acc) do
    parse_binding_fields(rest, [{field, {:integer, value}} | acc])
  end

  # field: min/max(...) — identifier-based (must be before generic Var clause)
  defp parse_binding_field([{:identifier, _, field}, {:delimiter, _, :colon},
                             {:identifier, _, op}, {:delimiter, _, :open_paren} | rest], acc)
       when op in [:min, :max, :list_head, :list_tail, :list_append, :list_prepend, :list_length, :list_empty] do
    case parse_builtin_call(op, [{:delimiter, {0, 0}, :open_paren} | rest]) do
      {:ok, expr, rest} ->
        parse_binding_fields(rest, [{field, {:builtin, expr}} | acc])
      {:error, _} = err -> err
    end
  end

  # field: map_op(...)
  defp parse_binding_field([{:identifier, _, field}, {:delimiter, _, :colon},
                             {:keyword, _, op} | rest], acc)
       when op in [:map_get, :map_put, :map_has, :map_delete, :map_size, :map_sum, :map_merge] do
    case parse_builtin_call(op, rest) do
      {:ok, expr, rest} ->
        parse_binding_fields(rest, [{field, {:builtin, expr}} | acc])
      {:error, _} = err -> err
    end
  end

  # field: [] or field: [elem, elem, ...]
  defp parse_binding_field([{:identifier, _, field}, {:delimiter, _, :colon}, {:delimiter, _, :open_bracket} | rest], acc) do
    case parse_list_literal(rest) do
      {:ok, elements, rest} ->
        parse_binding_fields(rest, [{field, {:list, elements}} | acc])
      {:error, _} = err -> err
    end
  end

  # field: Var
  defp parse_binding_field([{:identifier, _, field}, {:delimiter, _, :colon}, {:identifier, _, var} | rest], acc) do
    parse_binding_fields(rest, [{field, {:var, var}} | acc])
  end

  # field: :atom_value
  defp parse_binding_field([{:identifier, _, field}, {:delimiter, _, :colon}, {:atom, _, value} | rest], acc) do
    parse_binding_fields(rest, [{field, {:atom, value}} | acc])
  end

  defp parse_binding_field([token | _], _acc), do: {:error, {:expected_binding, token}}

  # --- Every block ---

  # every 100 do ... end
  defp parse_every([{:keyword, meta, :every}, {:integer, _, interval}, {:keyword, _, :do} | rest]) do
    case parse_handler_body(rest, []) do
      {:ok, body, rest} ->
        {:ok, %AST.Every{interval: {:integer, interval}, body: body, meta: meta}, rest}
      {:error, _} = err -> err
    end
  end

  # every param_name do ... end
  defp parse_every([{:keyword, meta, :every}, {:identifier, _, param_name}, {:keyword, _, :do} | rest]) do
    case parse_handler_body(rest, []) do
      {:ok, body, rest} ->
        {:ok, %AST.Every{interval: {:param, param_name}, body: body, meta: meta}, rest}
      {:error, _} = err -> err
    end
  end

  # --- Built-in function calls (map_get, map_put, min, max, etc.) ---

  defp parse_builtin_call(op, [{:delimiter, _, :open_paren} | rest]) do
    case parse_builtin_args(rest, []) do
      {:ok, args, rest} ->
        node = case op do
          op when op in [:min, :max] ->
            case args do
              [left, right] -> %AST.MinMax{op: op, left: left, right: right}
              _ -> {:error, {:wrong_arg_count, op, length(args)}}
            end
          _ ->
            %AST.MapOp{op: op, args: args}
        end
        case node do
          %{} -> {:ok, node, rest}
          {:error, _} = err -> err
        end
      {:error, _} = err -> err
    end
  end
  defp parse_builtin_call(op, _), do: {:error, {:expected_open_paren, op}}

  defp parse_builtin_args([{:delimiter, _, :close_paren} | rest], acc) do
    {:ok, Enum.reverse(acc), rest}
  end

  # nil as a special identifier → atom
  defp parse_builtin_args([{:identifier, _, :nil}, {:delimiter, _, :comma} | rest], acc) do
    parse_builtin_args(rest, [{:atom, "nil"} | acc])
  end

  defp parse_builtin_args([{:identifier, _, :nil}, {:delimiter, _, :close_paren} | rest], acc) do
    {:ok, Enum.reverse([{:atom, "nil"} | acc]), rest}
  end

  defp parse_builtin_args([{:identifier, _, name}, {:delimiter, _, :comma} | rest], acc) do
    parse_builtin_args(rest, [{:var, name} | acc])
  end

  defp parse_builtin_args([{:identifier, _, name}, {:delimiter, _, :close_paren} | rest], acc) do
    {:ok, Enum.reverse([{:var, name} | acc]), rest}
  end

  defp parse_builtin_args([{:integer, _, n}, {:delimiter, _, :comma} | rest], acc) do
    parse_builtin_args(rest, [{:integer, n} | acc])
  end

  defp parse_builtin_args([{:integer, _, n}, {:delimiter, _, :close_paren} | rest], acc) do
    {:ok, Enum.reverse([{:integer, n} | acc]), rest}
  end

  defp parse_builtin_args([{:atom, _, a}, {:delimiter, _, :comma} | rest], acc) do
    parse_builtin_args(rest, [{:atom, a} | acc])
  end

  defp parse_builtin_args([{:atom, _, a}, {:delimiter, _, :close_paren} | rest], acc) do
    {:ok, Enum.reverse([{:atom, a} | acc]), rest}
  end

  # Handle arithmetic expressions as arguments: e.g., current + 1
  defp parse_builtin_args([{:identifier, _, left}, {:operator, _, op}, {:identifier, _, right}, sep | rest], acc)
       when op in [:plus, :minus, :star, :slash] and elem(sep, 2) in [:comma, :close_paren] do
    expr = {:expr, %AST.ArithExpr{op: op, left: {:var, left}, right: {:var, right}}}
    case elem(sep, 2) do
      :comma -> parse_builtin_args(rest, [expr | acc])
      :close_paren -> {:ok, Enum.reverse([expr | acc]), rest}
    end
  end

  defp parse_builtin_args([{:identifier, _, left}, {:operator, _, op}, {:integer, _, right}, sep | rest], acc)
       when op in [:plus, :minus, :star, :slash] and elem(sep, 2) in [:comma, :close_paren] do
    expr = {:expr, %AST.ArithExpr{op: op, left: {:var, left}, right: {:integer, right}}}
    case elem(sep, 2) do
      :comma -> parse_builtin_args(rest, [expr | acc])
      :close_paren -> {:ok, Enum.reverse([expr | acc]), rest}
    end
  end

  defp parse_builtin_args([token | _], _acc), do: {:error, {:expected_builtin_arg, token}}

  # --- List literals ---

  # Empty list: []
  defp parse_list_literal([{:delimiter, _, :close_bracket} | rest]) do
    {:ok, [], rest}
  end

  # Populated list: [elem, elem, ...]
  defp parse_list_literal(tokens) do
    parse_list_elements(tokens, [])
  end

  defp parse_list_elements([{:delimiter, _, :close_bracket} | rest], acc) do
    {:ok, Enum.reverse(acc), rest}
  end

  defp parse_list_elements([{:integer, _, n}, {:delimiter, _, :comma} | rest], acc) do
    parse_list_elements(rest, [{:integer, n} | acc])
  end

  defp parse_list_elements([{:integer, _, n}, {:delimiter, _, :close_bracket} | rest], acc) do
    {:ok, Enum.reverse([{:integer, n} | acc]), rest}
  end

  defp parse_list_elements([{:atom, _, a}, {:delimiter, _, :comma} | rest], acc) do
    parse_list_elements(rest, [{:atom, a} | acc])
  end

  defp parse_list_elements([{:atom, _, a}, {:delimiter, _, :close_bracket} | rest], acc) do
    {:ok, Enum.reverse([{:atom, a} | acc]), rest}
  end

  defp parse_list_elements([{:identifier, _, v}, {:delimiter, _, :comma} | rest], acc) do
    parse_list_elements(rest, [{:var, v} | acc])
  end

  defp parse_list_elements([{:identifier, _, v}, {:delimiter, _, :close_bracket} | rest], acc) do
    {:ok, Enum.reverse([{:var, v} | acc]), rest}
  end

  defp parse_list_elements([token | _], _acc), do: {:error, {:expected_list_element, token}}

  # --- Guard: when EXPR ---

  defp parse_optional_guard([{:keyword, _, :when} | rest]) do
    case parse_guard_expr(rest) do
      {:ok, guard, rest} -> {guard, rest}
      {:error, _} -> {nil, [{:keyword, nil, :when} | rest]}
    end
  end

  defp parse_optional_guard(rest), do: {nil, rest}

  defp parse_guard_expr(tokens) do
    case parse_guard_comparison(tokens) do
      {:ok, left, [{:keyword, _, :and} | rest]} ->
        case parse_guard_expr(rest) do
          {:ok, right, rest} ->
            {:ok, %AST.CompoundGuard{op: :and, left: left, right: right}, rest}
          err -> err
        end
      {:ok, left, [{:keyword, _, :or} | rest]} ->
        case parse_guard_expr(rest) do
          {:ok, right, rest} ->
            {:ok, %AST.CompoundGuard{op: :or, left: left, right: right}, rest}
          err -> err
        end
      other -> other
    end
  end

  # field == :value or field == value
  defp parse_guard_comparison([{:identifier, _, field}, {:operator, _, :==}, {:atom, _, value} | rest]) do
    {:ok, %AST.Guard{field: field, op: :==, value: {:atom, value}}, rest}
  end

  defp parse_guard_comparison([{:identifier, _, field}, {:operator, _, :==}, {:identifier, _, value} | rest]) do
    {:ok, %AST.Guard{field: field, op: :==, value: {:var, value}}, rest}
  end

  defp parse_guard_comparison([{:identifier, _, field}, {:operator, _, :==}, {:integer, _, value} | rest]) do
    {:ok, %AST.Guard{field: field, op: :==, value: {:integer, value}}, rest}
  end

  # field > value, field < value, field >= value, field <= value
  defp parse_guard_comparison([{:identifier, _, field}, {:operator, _, op}, {:identifier, _, value} | rest])
       when op in [:>, :<, :>=, :<=] do
    {:ok, %AST.Guard{field: field, op: op, value: {:var, value}}, rest}
  end

  defp parse_guard_comparison([{:identifier, _, field}, {:operator, _, op}, {:integer, _, value} | rest])
       when op in [:>, :<, :>=, :<=] do
    {:ok, %AST.Guard{field: field, op: op, value: {:integer, value}}, rest}
  end

  # S in 100..199
  defp parse_guard_comparison([{:identifier, _, field}, {:keyword, _, :in}, {:integer, _, low}, {:operator, _, :range}, {:integer, _, high} | rest]) do
    {:ok, %AST.Guard{field: field, op: :in, value: {:range, low, high}}, rest}
  end

  defp parse_guard_comparison([token | _]), do: {:error, {:expected_guard_expr, token}}

  # --- Handler Body ---

  defp parse_handler_body([{:keyword, _, :end} | rest], acc) do
    {:ok, Enum.reverse(acc), rest}
  end

  defp parse_handler_body([{:keyword, meta, :emit} | rest], acc) do
    case parse_emit(rest, meta) do
      {:ok, emit, rest} -> parse_handler_body(rest, [emit | acc])
      {:error, _} = err -> err
    end
  end

  defp parse_handler_body([{:keyword, meta, :transition} | rest], acc) do
    case parse_transition(rest, meta) do
      {:ok, trans, rest} -> parse_handler_body(rest, [trans | acc])
      {:error, _} = err -> err
    end
  end

  defp parse_handler_body([{:keyword, meta, :start_timer} | rest], acc) do
    case rest do
      [{:delimiter, _, :open_paren}, {:atom, _, name}, {:delimiter, _, :close_paren} | rest] ->
        parse_handler_body(rest, [%AST.StartTimer{name: name, meta: meta} | acc])
      [token | _] -> {:error, {:expected_timer_arg, token}}
    end
  end

  defp parse_handler_body([{:keyword, meta, :cancel_timer} | rest], acc) do
    case rest do
      [{:delimiter, _, :open_paren}, {:atom, _, name}, {:delimiter, _, :close_paren} | rest] ->
        parse_handler_body(rest, [%AST.CancelTimer{name: name, meta: meta} | acc])
      [token | _] -> {:error, {:expected_timer_arg, token}}
    end
  end

  defp parse_handler_body([{:keyword, meta, :restart_timer} | rest], acc) do
    case parse_restart_timer_args(rest) do
      {:ok, name, args, rest} ->
        parse_handler_body(rest, [%AST.RestartTimer{name: name, args: args, meta: meta} | acc])
      {:error, _} = err -> err
    end
  end

  defp parse_handler_body([{:keyword, meta, :retransmit_last_response} | rest], acc) do
    parse_handler_body(rest, [%AST.FunctionCall{name: :retransmit_last_response, args: [], meta: meta} | acc])
  end

  # if EXPR do ... else ... end
  defp parse_handler_body([{:keyword, meta, :if} | rest], acc) do
    case parse_if_else(rest, meta) do
      {:ok, if_node, rest} -> parse_handler_body(rest, [if_node | acc])
      {:error, _} = err -> err
    end
  end

  # send :target {:tag, field: value}
  defp parse_handler_body([{:keyword, meta, :send}, {:atom, _, target} | rest], acc) do
    case rest do
      [{:delimiter, _, :open_brace}, {:atom, _, tag} | rest] ->
        case parse_binding_fields(rest, []) do
          {:ok, fields, rest} ->
            node = %AST.Send{target: target, tag: tag, fields: fields, meta: meta}
            parse_handler_body(rest, [node | acc])
          {:error, _} = err -> err
        end
      [token | _] -> {:error, {:expected_send_message, token}}
    end
  end

  # send with variable target: send VarName {:tag, fields}
  defp parse_handler_body([{:keyword, meta, :send}, {:identifier, _, target} | rest], acc) do
    case rest do
      [{:delimiter, _, :open_brace}, {:atom, _, tag} | rest] ->
        case parse_binding_fields(rest, []) do
          {:ok, fields, rest} ->
            node = %AST.Send{target: {:var, target}, tag: tag, fields: fields, meta: meta}
            parse_handler_body(rest, [node | acc])
          {:error, _} = err -> err
        end
      [token | _] -> {:error, {:expected_send_message, token}}
    end
  end

  # noop — intentional no-op
  defp parse_handler_body([{:keyword, meta, :noop} | rest], acc) do
    parse_handler_body(rest, [%AST.Noop{meta: meta} | acc])
  end

  # broadcast {:tag, field: value, ...}
  defp parse_handler_body([{:keyword, meta, :broadcast}, {:delimiter, _, :open_brace}, {:atom, _, tag} | rest], acc) do
    case parse_binding_fields(rest, []) do
      {:ok, fields, rest} ->
        node = %AST.Broadcast{tag: tag, fields: fields, meta: meta}
        parse_handler_body(rest, [node | acc])
      {:error, _} = err -> err
    end
  end

  # solve relation_name(field: var, ...) do body end
  defp parse_handler_body([{:keyword, meta, :solve}, {:identifier, _, rel_name},
                            {:delimiter, _, :open_paren} | rest], acc) do
    case parse_solve_bindings(rest) do
      {:ok, bindings, [{:keyword, _, :do} | rest]} ->
        case parse_handler_body(rest, []) do
          {:ok, body, rest} ->
            node = %AST.Solve{relation: rel_name, bindings: bindings, body: body, meta: meta}
            parse_handler_body(rest, [node | acc])
          {:error, _} = err -> err
        end
      {:ok, _, [token | _]} -> {:error, {:expected_do, token}}
      {:error, _} = err -> err
    end
  end

  # var = mod/sub.function(...) — Gleam extern call with binding.
  # The look-ahead requires another identifier after the slash so that plain
  # arithmetic like `half = cluster_size / 2` falls through to the arithmetic
  # clauses below.
  defp parse_handler_body([{:identifier, meta, bind_var}, {:operator, _, :equals},
                            {:identifier, _, first_seg}, {:operator, _, :slash},
                            {:identifier, _, _} = next_seg | rest], acc) do
    case collect_gleam_module_path([first_seg], [{:operator, nil, :slash}, next_seg | rest]) do
      {:ok, mod_atom, func, [{:delimiter, _, :open_paren} | rest]} ->
        case parse_extern_args(rest) do
          {:ok, args, rest} ->
            node = %AST.ExternCall{module: {:gleam_mod, mod_atom}, function: func, args: args, bind: bind_var, meta: meta}
            parse_handler_body(rest, [node | acc])
          {:error, _} = err -> err
        end
      {:error, _} = err -> err
    end
  end

  # var = Mod.Sub.function(...) — extern call with binding (Elixir module)
  defp parse_handler_body([{:identifier, meta, bind_var}, {:operator, _, :equals},
                            {:identifier, _, first_seg}, {:operator, _, :dot} | rest], acc) do
    case collect_dotted_name([first_seg], [{:operator, nil, :dot} | rest]) do
      {:ok, segments, func, [{:delimiter, _, :open_paren} | rest]} ->
        # Check for Erlang.module.function pattern
        mod = case segments do
          [:Erlang, erl_mod] -> {:erlang_mod, Atom.to_string(erl_mod)}
          _ -> Enum.join(Enum.map(segments, &Atom.to_string/1), ".")
        end
        case parse_extern_args(rest) do
          {:ok, args, rest} ->
            node = %AST.ExternCall{module: mod, function: func, args: args, bind: bind_var, meta: meta}
            parse_handler_body(rest, [node | acc])
          {:error, _} = err -> err
        end
      {:error, _} = err -> err
    end
  end

  # var = :erlang.function(...) — extern call with binding (Erlang module)
  defp parse_handler_body([{:identifier, meta, bind_var}, {:operator, _, :equals},
                            {:atom, _, mod}, {:operator, _, :dot},
                            {:identifier, _, func}, {:delimiter, _, :open_paren} | rest], acc) do
    case parse_extern_args(rest) do
      {:ok, args, rest} ->
        node = %AST.ExternCall{module: {:erlang_mod, mod}, function: func, args: args, bind: bind_var, meta: meta}
        parse_handler_body(rest, [node | acc])
      {:error, _} = err -> err
    end
  end

  # mod/sub.function(...) — Gleam extern call without binding. Look-ahead
  # requires another identifier after the slash so plain arithmetic doesn't
  # accidentally match.
  defp parse_handler_body([{:identifier, meta, first_seg}, {:operator, _, :slash},
                            {:identifier, _, _} = next_seg | rest], acc) do
    case collect_gleam_module_path([first_seg], [{:operator, nil, :slash}, next_seg | rest]) do
      {:ok, mod_atom, func, [{:delimiter, _, :open_paren} | rest]} ->
        case parse_extern_args(rest) do
          {:ok, args, rest} ->
            node = %AST.ExternCall{module: {:gleam_mod, mod_atom}, function: func, args: args, bind: nil, meta: meta}
            parse_handler_body(rest, [node | acc])
          {:error, _} = err -> err
        end
      {:error, _} = err -> err
    end
  end

  # Mod.Sub.function(...) — extern call without binding (Elixir or Erlang module)
  defp parse_handler_body([{:identifier, meta, first_seg}, {:operator, _, :dot} | rest], acc) do
    case collect_dotted_name([first_seg], [{:operator, nil, :dot} | rest]) do
      {:ok, segments, func, [{:delimiter, _, :open_paren} | rest]} ->
        mod = case segments do
          [:Erlang, erl_mod] -> {:erlang_mod, Atom.to_string(erl_mod)}
          _ -> Enum.join(Enum.map(segments, &Atom.to_string/1), ".")
        end
        case parse_extern_args(rest) do
          {:ok, args, rest} ->
            node = %AST.ExternCall{module: mod, function: func, args: args, bind: nil, meta: meta}
            parse_handler_body(rest, [node | acc])
          {:error, _} = err -> err
        end
      {:error, _} = err -> err
    end
  end

  # :erlang.function(...) — extern call without binding (Erlang module)
  defp parse_handler_body([{:atom, meta, mod}, {:operator, _, :dot},
                            {:identifier, _, func}, {:delimiter, _, :open_paren} | rest], acc) do
    case parse_extern_args(rest) do
      {:ok, args, rest} ->
        node = %AST.ExternCall{module: {:erlang_mod, mod}, function: func, args: args, bind: nil, meta: meta}
        parse_handler_body(rest, [node | acc])
      {:error, _} = err -> err
    end
  end

  # var = Var OP Var (arithmetic binding)
  defp parse_handler_body([{:identifier, meta, bind_var}, {:operator, _, :equals},
                            {:identifier, _, left}, {:operator, _, op},
                            {:identifier, _, right} | rest], acc)
       when op in [:minus, :plus, :star, :slash] do
    expr = %AST.ArithExpr{op: op, left: {:var, left}, right: {:var, right}}
    parse_handler_body(rest, [%AST.VarBinding{name: bind_var, expr: expr, meta: meta} | acc])
  end

  # var = Var OP Integer (arithmetic binding)
  defp parse_handler_body([{:identifier, meta, bind_var}, {:operator, _, :equals},
                            {:identifier, _, left}, {:operator, _, op},
                            {:integer, _, right} | rest], acc)
       when op in [:minus, :plus, :star, :slash] do
    expr = %AST.ArithExpr{op: op, left: {:var, left}, right: {:integer, right}}
    parse_handler_body(rest, [%AST.VarBinding{name: bind_var, expr: expr, meta: meta} | acc])
  end

  # var = Integer OP Var (int-first arithmetic binding)
  defp parse_handler_body([{:identifier, meta, bind_var}, {:operator, _, :equals},
                            {:integer, _, left}, {:operator, _, op},
                            {:identifier, _, right} | rest], acc)
       when op in [:minus, :plus, :star, :slash] do
    expr = %AST.ArithExpr{op: op, left: {:integer, left}, right: {:var, right}}
    parse_handler_body(rest, [%AST.VarBinding{name: bind_var, expr: expr, meta: meta} | acc])
  end

  # var = :atom (atom literal binding)
  defp parse_handler_body([{:identifier, meta, bind_var}, {:operator, _, :equals},
                            {:atom, _, value} | rest], acc) do
    parse_handler_body(rest, [%AST.VarBinding{name: bind_var, expr: {:atom, value}, meta: meta} | acc])
  end

  # var = integer (integer literal binding)
  defp parse_handler_body([{:identifier, meta, bind_var}, {:operator, _, :equals},
                            {:integer, _, value} | rest], acc) do
    parse_handler_body(rest, [%AST.VarBinding{name: bind_var, expr: {:integer, value}, meta: meta} | acc])
  end

  # var = min/max(...) — identifier-based built-in
  defp parse_handler_body([{:identifier, meta, bind_var}, {:operator, _, :equals},
                            {:identifier, _, op}, {:delimiter, _, :open_paren} | rest], acc)
       when op in [:min, :max, :list_head, :list_tail, :list_append, :list_prepend, :list_length, :list_empty] do
    case parse_builtin_call(op, [{:delimiter, {0, 0}, :open_paren} | rest]) do
      {:ok, expr, rest} ->
        parse_handler_body(rest, [%AST.VarBinding{name: bind_var, expr: expr, meta: meta} | acc])
      {:error, _} = err -> err
    end
  end

  # var = map_op(...)
  defp parse_handler_body([{:identifier, meta, bind_var}, {:operator, _, :equals},
                            {:keyword, _, op} | rest], acc)
       when op in [:map_get, :map_put, :map_has, :map_delete, :map_size, :map_sum, :map_merge] do
    case parse_builtin_call(op, rest) do
      {:ok, expr, rest} ->
        parse_handler_body(rest, [%AST.VarBinding{name: bind_var, expr: expr, meta: meta} | acc])
      {:error, _} = err -> err
    end
  end

  # var = Var (simple copy binding) — must come after extern call patterns
  defp parse_handler_body([{:identifier, meta, bind_var}, {:operator, _, :equals},
                            {:identifier, _, source_var} | rest], acc) do
    parse_handler_body(rest, [%AST.VarBinding{name: bind_var, expr: {:var, source_var}, meta: meta} | acc])
  end

  defp parse_handler_body([{:identifier, meta, name} | rest], acc) do
    # Bare function call
    parse_handler_body(rest, [%AST.FunctionCall{name: name, args: [], meta: meta} | acc])
  end

  defp parse_handler_body([token | _], _acc), do: {:error, {:unexpected_in_handler, token}}
  defp parse_handler_body([], _acc), do: {:error, :unexpected_eof}

  # Parse extern call arguments — uses ) as terminator instead of }
  defp parse_extern_args([{:delimiter, _, :close_paren} | rest]) do
    {:ok, [], rest}
  end

  defp parse_extern_args(tokens) do
    parse_extern_arg_fields(tokens, [])
  end

  # Parse solve call bindings — field: Var or field: literal, terminated by )
  defp parse_solve_bindings([{:delimiter, _, :close_paren} | rest]), do: {:ok, [], rest}
  defp parse_solve_bindings(tokens), do: parse_solve_binding_fields(tokens, [])

  defp parse_solve_binding_fields([{:delimiter, _, :close_paren} | rest], acc), do: {:ok, Enum.reverse(acc), rest}
  defp parse_solve_binding_fields([{:delimiter, _, :comma} | rest], acc), do: parse_solve_binding_field(rest, acc)
  defp parse_solve_binding_fields(tokens, []), do: parse_solve_binding_field(tokens, [])

  defp parse_solve_binding_field([{:identifier, _, field}, {:delimiter, _, :colon}, {:identifier, _, var} | rest], acc) do
    parse_solve_binding_fields(rest, [{field, {:var, var}} | acc])
  end
  defp parse_solve_binding_field([{:identifier, _, field}, {:delimiter, _, :colon}, {:integer, _, val} | rest], acc) do
    parse_solve_binding_fields(rest, [{field, {:integer, val}} | acc])
  end
  defp parse_solve_binding_field([{:identifier, _, field}, {:delimiter, _, :colon}, {:atom, _, val} | rest], acc) do
    parse_solve_binding_fields(rest, [{field, {:atom, val}} | acc])
  end
  defp parse_solve_binding_field([token | _], _acc), do: {:error, {:expected_solve_binding, token}}

  defp parse_extern_arg_fields([{:delimiter, _, :close_paren} | rest], acc) do
    {:ok, Enum.reverse(acc), rest}
  end

  defp parse_extern_arg_fields([{:delimiter, _, :comma} | rest], acc) do
    parse_extern_arg_field(rest, acc)
  end

  defp parse_extern_arg_fields(tokens, []) do
    parse_extern_arg_field(tokens, [])
  end

  defp parse_extern_arg_field([{:identifier, _, field}, {:delimiter, _, :colon}, {:identifier, _, var} | rest], acc) do
    parse_extern_arg_fields(rest, [{field, {:var, var}} | acc])
  end

  defp parse_extern_arg_field([{:identifier, _, field}, {:delimiter, _, :colon}, {:atom, _, value} | rest], acc) do
    parse_extern_arg_fields(rest, [{field, {:atom, value}} | acc])
  end

  # Allow keywords as extern call argument names (state: val, protocol: val, etc.)
  defp parse_extern_arg_field([{:keyword, _, field}, {:delimiter, _, :colon}, {:identifier, _, var} | rest], acc) do
    parse_extern_arg_fields(rest, [{field, {:var, var}} | acc])
  end

  defp parse_extern_arg_field([{:keyword, _, field}, {:delimiter, _, :colon}, {:atom, _, value} | rest], acc) do
    parse_extern_arg_fields(rest, [{field, {:atom, value}} | acc])
  end

  defp parse_extern_arg_field([token | _], _acc), do: {:error, {:expected_extern_arg, token}}

  # --- If/Else ---

  # if EXPR do BODY else BODY end
  defp parse_if_else(tokens, meta) do
    case parse_condition(tokens) do
      {:ok, condition, [{:keyword, _, :do} | rest]} ->
        case parse_if_body(rest, []) do
          {:ok, then_body, :else, rest} ->
            case parse_if_body(rest, []) do
              {:ok, else_body, :end, rest} ->
                {:ok, %AST.IfElse{condition: condition, then_body: then_body, else_body: else_body, meta: meta}, rest}
              {:error, _} = err -> err
            end
          {:ok, then_body, :end, rest} ->
            {:ok, %AST.IfElse{condition: condition, then_body: then_body, else_body: [], meta: meta}, rest}
          {:error, _} = err -> err
        end
      {:ok, _, [token | _]} -> {:error, {:expected_do_after_if, token}}
      {:error, _} = err -> err
    end
  end

  # Parse handler body stopping at `else` or `end`, returning which was found
  # Supports all the same statements as parse_handler_body
  defp parse_if_body([{:keyword, _, :else} | rest], acc), do: {:ok, Enum.reverse(acc), :else, rest}
  defp parse_if_body([{:keyword, _, :end} | rest], acc), do: {:ok, Enum.reverse(acc), :end, rest}

  defp parse_if_body([{:keyword, meta, :emit} | rest], acc) do
    case parse_emit(rest, meta) do
      {:ok, emit, rest} -> parse_if_body(rest, [emit | acc])
      {:error, _} = err -> err
    end
  end

  defp parse_if_body([{:keyword, meta, :transition} | rest], acc) do
    case parse_transition(rest, meta) do
      {:ok, trans, rest} -> parse_if_body(rest, [trans | acc])
      {:error, _} = err -> err
    end
  end

  # send in if body (literal target)
  defp parse_if_body([{:keyword, meta, :send}, {:atom, _, target} | rest], acc) do
    case rest do
      [{:delimiter, _, :open_brace}, {:atom, _, tag} | rest] ->
        case parse_binding_fields(rest, []) do
          {:ok, fields, rest} ->
            node = %AST.Send{target: target, tag: tag, fields: fields, meta: meta}
            parse_if_body(rest, [node | acc])
          {:error, _} = err -> err
        end
      [token | _] -> {:error, {:expected_send_message, token}}
    end
  end

  # send in if body (variable target)
  defp parse_if_body([{:keyword, meta, :send}, {:identifier, _, target} | rest], acc) do
    case rest do
      [{:delimiter, _, :open_brace}, {:atom, _, tag} | rest] ->
        case parse_binding_fields(rest, []) do
          {:ok, fields, rest} ->
            node = %AST.Send{target: {:var, target}, tag: tag, fields: fields, meta: meta}
            parse_if_body(rest, [node | acc])
          {:error, _} = err -> err
        end
      [token | _] -> {:error, {:expected_send_message, token}}
    end
  end

  # noop inside if body
  defp parse_if_body([{:keyword, _meta, :noop} | rest], acc) do
    parse_if_body(rest, acc)
  end

  # broadcast inside if body
  defp parse_if_body([{:keyword, meta, :broadcast}, {:delimiter, _, :open_brace}, {:atom, _, tag} | rest], acc) do
    case parse_binding_fields(rest, []) do
      {:ok, fields, rest} ->
        node = %AST.Broadcast{tag: tag, fields: fields, meta: meta}
        parse_if_body(rest, [node | acc])
      {:error, _} = err -> err
    end
  end

  # Nested if/else inside if body
  defp parse_if_body([{:keyword, meta, :if} | rest], acc) do
    case parse_if_else(rest, meta) do
      {:ok, if_node, rest} -> parse_if_body(rest, [if_node | acc])
      {:error, _} = err -> err
    end
  end

  # var = mod/sub.function(...) — Gleam extern call with binding inside if body
  # Must come before arithmetic bindings because slash is both a path separator and arithmetic op
  defp parse_if_body([{:identifier, meta, bind_var}, {:operator, _, :equals},
                       {:identifier, _, first_seg}, {:operator, _, :slash} | rest], acc) do
    case collect_gleam_module_path([first_seg], [{:operator, nil, :slash} | rest]) do
      {:ok, mod_atom, func, [{:delimiter, _, :open_paren} | rest]} ->
        case parse_extern_args(rest) do
          {:ok, args, rest} ->
            node = %AST.ExternCall{module: {:gleam_mod, mod_atom}, function: func, args: args, bind: bind_var, meta: meta}
            parse_if_body(rest, [node | acc])
          {:error, _} = err -> err
        end
      {:error, _} = err -> err
    end
  end

  # var = Var OP Var (arithmetic binding in if body)
  defp parse_if_body([{:identifier, meta, bind_var}, {:operator, _, :equals},
                       {:identifier, _, left}, {:operator, _, op},
                       {:identifier, _, right} | rest], acc)
       when op in [:minus, :plus, :star, :slash] do
    expr = %AST.ArithExpr{op: op, left: {:var, left}, right: {:var, right}}
    parse_if_body(rest, [%AST.VarBinding{name: bind_var, expr: expr, meta: meta} | acc])
  end

  # var = Var OP Integer (arithmetic binding in if body)
  defp parse_if_body([{:identifier, meta, bind_var}, {:operator, _, :equals},
                       {:identifier, _, left}, {:operator, _, op},
                       {:integer, _, right} | rest], acc)
       when op in [:minus, :plus, :star, :slash] do
    expr = %AST.ArithExpr{op: op, left: {:var, left}, right: {:integer, right}}
    parse_if_body(rest, [%AST.VarBinding{name: bind_var, expr: expr, meta: meta} | acc])
  end

  # var = Integer OP Var (int-first arithmetic in if body)
  defp parse_if_body([{:identifier, meta, bind_var}, {:operator, _, :equals},
                       {:integer, _, left}, {:operator, _, op},
                       {:identifier, _, right} | rest], acc)
       when op in [:minus, :plus, :star, :slash] do
    expr = %AST.ArithExpr{op: op, left: {:integer, left}, right: {:var, right}}
    parse_if_body(rest, [%AST.VarBinding{name: bind_var, expr: expr, meta: meta} | acc])
  end

  # mod/sub.function(...) — Gleam extern call without binding inside if body
  defp parse_if_body([{:identifier, meta, first_seg}, {:operator, _, :slash} | rest], acc) do
    case collect_gleam_module_path([first_seg], [{:operator, nil, :slash} | rest]) do
      {:ok, mod_atom, func, [{:delimiter, _, :open_paren} | rest]} ->
        case parse_extern_args(rest) do
          {:ok, args, rest} ->
            node = %AST.ExternCall{module: {:gleam_mod, mod_atom}, function: func, args: args, bind: nil, meta: meta}
            parse_if_body(rest, [node | acc])
          {:error, _} = err -> err
        end
      {:error, _} = err -> err
    end
  end

  # var = Mod.Sub.function(...) — extern call with binding inside if body
  defp parse_if_body([{:identifier, meta, bind_var}, {:operator, _, :equals},
                       {:identifier, _, first_seg}, {:operator, _, :dot} | rest], acc) do
    case collect_dotted_name([first_seg], [{:operator, nil, :dot} | rest]) do
      {:ok, segments, func, [{:delimiter, _, :open_paren} | rest]} ->
        mod = case segments do
          [:Erlang, erl_mod] -> {:erlang_mod, Atom.to_string(erl_mod)}
          _ -> Enum.join(Enum.map(segments, &Atom.to_string/1), ".")
        end
        case parse_extern_args(rest) do
          {:ok, args, rest} ->
            node = %AST.ExternCall{module: mod, function: func, args: args, bind: bind_var, meta: meta}
            parse_if_body(rest, [node | acc])
          {:error, _} = err -> err
        end
      {:error, _} = err -> err
    end
  end

  # var = min/max(...) inside if body — identifier-based
  defp parse_if_body([{:identifier, meta, bind_var}, {:operator, _, :equals},
                       {:identifier, _, op}, {:delimiter, _, :open_paren} | rest], acc)
       when op in [:min, :max, :list_head, :list_tail, :list_append, :list_prepend, :list_length, :list_empty] do
    case parse_builtin_call(op, [{:delimiter, {0, 0}, :open_paren} | rest]) do
      {:ok, expr, rest} ->
        parse_if_body(rest, [%AST.VarBinding{name: bind_var, expr: expr, meta: meta} | acc])
      {:error, _} = err -> err
    end
  end

  # var = map_op(...) inside if body
  defp parse_if_body([{:identifier, meta, bind_var}, {:operator, _, :equals},
                       {:keyword, _, op} | rest], acc)
       when op in [:map_get, :map_put, :map_has, :map_delete, :map_size, :map_sum, :map_merge] do
    case parse_builtin_call(op, rest) do
      {:ok, expr, rest} ->
        parse_if_body(rest, [%AST.VarBinding{name: bind_var, expr: expr, meta: meta} | acc])
      {:error, _} = err -> err
    end
  end

  defp parse_if_body([token | _], _acc), do: {:error, {:unexpected_in_if, token}}
  defp parse_if_body([], _acc), do: {:error, :unexpected_eof}

  # Condition: supports and/or boolean logic
  defp parse_condition(tokens) do
    case parse_single_condition(tokens) do
      {:ok, left, [{:keyword, _, :and} | rest]} ->
        case parse_condition(rest) do
          {:ok, right, rest} ->
            {:ok, %AST.CompoundComparison{op: :and, left: left, right: right}, rest}
          err -> err
        end
      {:ok, left, [{:keyword, _, :or} | rest]} ->
        case parse_condition(rest) do
          {:ok, right, rest} ->
            {:ok, %AST.CompoundComparison{op: :or, left: left, right: right}, rest}
          err -> err
        end
      other -> other
    end
  end

  # Single comparison: expr OP expr
  defp parse_single_condition([{:identifier, _, left}, {:operator, _, op}, {:identifier, _, right} | rest])
       when op in [:<=, :>=, :==, :!=, :>, :<] do
    {:ok, %AST.Comparison{left: {:var, left}, op: op, right: {:var, right}}, rest}
  end

  defp parse_single_condition([{:identifier, _, left}, {:operator, _, op}, {:integer, _, right} | rest])
       when op in [:<=, :>=, :==, :!=, :>, :<] do
    {:ok, %AST.Comparison{left: {:var, left}, op: op, right: {:integer, right}}, rest}
  end

  defp parse_single_condition([{:integer, _, left}, {:operator, _, op}, {:identifier, _, right} | rest])
       when op in [:<=, :>=, :==, :!=, :>, :<] do
    {:ok, %AST.Comparison{left: {:integer, left}, op: op, right: {:var, right}}, rest}
  end

  defp parse_single_condition([{:identifier, _, left}, {:operator, _, op}, {:atom, _, right} | rest])
       when op in [:<=, :>=, :==, :!=, :>, :<] do
    {:ok, %AST.Comparison{left: {:var, left}, op: op, right: {:atom, right}}, rest}
  end

  defp parse_single_condition([token | _]), do: {:error, {:expected_condition, token}}

  # --- Arithmetic expressions in emit fields ---
  # Extends parse_binding_field to handle: field: EXPR - EXPR, field: EXPR + EXPR

  defp parse_restart_timer_args([{:delimiter, _, :open_paren}, {:atom, _, name}, {:delimiter, _, :comma} | rest]) do
    # Consume tokens until close paren — store as raw tokens for now
    case consume_until_close_paren(rest, [], 0) do
      {:ok, args, rest} -> {:ok, name, args, rest}
      err -> err
    end
  end

  defp parse_restart_timer_args([token | _]), do: {:error, {:expected_restart_timer_args, token}}

  defp consume_until_close_paren([{:delimiter, _, :close_paren} | rest], acc, 0) do
    {:ok, Enum.reverse(acc), rest}
  end

  defp consume_until_close_paren([{:delimiter, _, :open_paren} = t | rest], acc, depth) do
    consume_until_close_paren(rest, [t | acc], depth + 1)
  end

  defp consume_until_close_paren([{:delimiter, _, :close_paren} = t | rest], acc, depth) do
    consume_until_close_paren(rest, [t | acc], depth - 1)
  end

  defp consume_until_close_paren([t | rest], acc, depth) do
    consume_until_close_paren(rest, [t | acc], depth)
  end

  defp consume_until_close_paren([], _acc, _depth), do: {:error, :unexpected_eof}

  # --- Emit: emit {:tag, field1: Expr} ---

  defp parse_emit([{:delimiter, _, :open_brace}, {:atom, _, tag} | rest], meta) do
    case parse_binding_fields(rest, []) do
      {:ok, fields, rest} ->
        {:ok, %AST.Emit{tag: tag, fields: fields, meta: meta}, rest}
      {:error, _} = err -> err
    end
  end

  defp parse_emit([token | _], _meta), do: {:error, {:expected_emit_message, token}}

  # --- Transition: transition field: expr ---

  # transition field: :atom
  defp parse_transition([{:identifier, _, field}, {:delimiter, _, :colon}, {:atom, _, value} | rest], meta) do
    {:ok, %AST.Transition{field: field, value: value, meta: meta}, rest}
  end

  # transition field: Var OP Var
  defp parse_transition([{:identifier, _, field}, {:delimiter, _, :colon},
                          {:identifier, _, left}, {:operator, _, op},
                          {:identifier, _, right} | rest], meta)
       when op in [:minus, :plus, :star, :slash] do
    expr = %AST.ArithExpr{op: op, left: {:var, left}, right: {:var, right}}
    {:ok, %AST.Transition{field: field, value: {:expr, expr}, meta: meta}, rest}
  end

  # transition field: Var OP Integer
  defp parse_transition([{:identifier, _, field}, {:delimiter, _, :colon},
                          {:identifier, _, left}, {:operator, _, op},
                          {:integer, _, right} | rest], meta)
       when op in [:minus, :plus, :star, :slash] do
    expr = %AST.ArithExpr{op: op, left: {:var, left}, right: {:integer, right}}
    {:ok, %AST.Transition{field: field, value: {:expr, expr}, meta: meta}, rest}
  end

  # transition field: Integer OP Var
  defp parse_transition([{:identifier, _, field}, {:delimiter, _, :colon},
                          {:integer, _, left}, {:operator, _, op},
                          {:identifier, _, right} | rest], meta)
       when op in [:minus, :plus, :star, :slash] do
    expr = %AST.ArithExpr{op: op, left: {:integer, left}, right: {:var, right}}
    {:ok, %AST.Transition{field: field, value: {:expr, expr}, meta: meta}, rest}
  end

  # transition field: integer (must come after Integer OP Var)
  defp parse_transition([{:identifier, _, field}, {:delimiter, _, :colon}, {:integer, _, value} | rest], meta) do
    {:ok, %AST.Transition{field: field, value: {:integer, value}, meta: meta}, rest}
  end

  # transition field: map_op(...)
  defp parse_transition([{:identifier, _, field}, {:delimiter, _, :colon}, {:keyword, _, op} | rest], meta)
       when op in [:map_get, :map_put, :map_has, :map_delete, :map_size, :map_sum, :map_merge] do
    case parse_builtin_call(op, rest) do
      {:ok, expr, rest} -> {:ok, %AST.Transition{field: field, value: {:builtin, expr}, meta: meta}, rest}
      {:error, _} = err -> err
    end
  end

  # transition field: min/max(...) — identifier followed by open_paren
  defp parse_transition([{:identifier, _, field}, {:delimiter, _, :colon},
                          {:identifier, _, op}, {:delimiter, _, :open_paren} | rest], meta)
       when op in [:min, :max, :list_head, :list_tail, :list_append, :list_prepend, :list_length, :list_empty] do
    case parse_builtin_call(op, [{:delimiter, {0, 0}, :open_paren} | rest]) do
      {:ok, expr, rest} -> {:ok, %AST.Transition{field: field, value: {:builtin, expr}, meta: meta}, rest}
      {:error, _} = err -> err
    end
  end

  # transition field: Var (simple variable reference)
  defp parse_transition([{:identifier, _, field}, {:delimiter, _, :colon}, {:identifier, _, var} | rest], meta) do
    {:ok, %AST.Transition{field: field, value: {:var, var}, meta: meta}, rest}
  end

  defp parse_transition([token | _], _meta), do: {:error, {:expected_transition, token}}

  # --- State Declaration: state field: :v1 | :v2 | :v3 ---

  defp parse_state_decl([{:keyword, meta, :state} | rest]) do
    case rest do
      [{:identifier, _, field}, {:delimiter, _, :colon} | rest] ->
        case parse_type_union(rest, []) do
          {:ok, types, [{:identifier, _, :sensitive} | rest]} ->
            {:ok, %AST.StateDecl{field: field, type_union: types, sensitive: true, meta: meta}, rest}
          {:ok, types, rest} ->
            {:ok, %AST.StateDecl{field: field, type_union: types, meta: meta}, rest}
          {:error, _} = err -> err
        end
      [token | _] -> {:error, {:expected_state_field, token}}
    end
  end

  # Atom union: :a | :b | :c
  defp parse_type_union([{:atom, _, value} | rest], acc) do
    case rest do
      [{:delimiter, _, :pipe} | rest] -> parse_type_union(rest, [value | acc])
      _ -> {:ok, Enum.reverse([value | acc]), rest}
    end
  end

  # Identifier type: integer, atom, term, etc. (single type, no union)
  defp parse_type_union([{:identifier, _, type} | rest], []) do
    {:ok, [{:type, type}], rest}
  end

  defp parse_type_union([token | _], _acc), do: {:error, {:expected_type, token}}

  # --- Relation ---

  defp parse_relation([{:keyword, meta, :relation}, {:identifier, _, name}, {:delimiter, _, :open_paren} | rest]) do
    case parse_typed_fields_paren(rest, []) do
      {:ok, params, [{:keyword, _, :do} | rest]} ->
        case parse_relation_body(rest, [], nil) do
          {:ok, facts, equation, rest} ->
            relation = %AST.Relation{name: name, params: params, facts: facts, meta: meta}
            # Attach equation if present
            relation = if equation, do: Map.put(relation, :equation, equation), else: relation
            {:ok, relation, rest}
          {:error, _} = err -> err
        end
      {:ok, _, [token | _]} -> {:error, {:expected_do, token}}
      {:error, _} = err -> err
    end
  end

  defp parse_typed_fields_paren([{:delimiter, _, :close_paren} | rest], acc) do
    {:ok, Enum.reverse(acc), rest}
  end

  defp parse_typed_fields_paren([{:delimiter, _, :comma} | rest], acc) do
    parse_typed_field_paren(rest, acc)
  end

  defp parse_typed_fields_paren(tokens, []) do
    parse_typed_field_paren(tokens, [])
  end

  defp parse_typed_field_paren([{:identifier, _, name}, {:delimiter, _, :colon}, {:identifier, _, type} | rest], acc) do
    parse_typed_fields_paren(rest, [{name, type} | acc])
  end

  # Allow Vor keywords as extern parameter names (state, protocol, transition, emit, etc.)
  defp parse_typed_field_paren([{:keyword, _, name}, {:delimiter, _, :colon}, {:identifier, _, type} | rest], acc) do
    parse_typed_fields_paren(rest, [{name, type} | acc])
  end

  defp parse_relation_body([{:keyword, _, :end} | rest], facts, equation) do
    {:ok, Enum.reverse(facts), equation, rest}
  end

  defp parse_relation_body([{:keyword, _, :fact} | rest], facts, equation) do
    case rest do
      [{:delimiter, _, :open_paren} | rest] ->
        case parse_fact_fields(rest, []) do
          {:ok, fields, rest} -> parse_relation_body(rest, [%AST.Fact{fields: fields} | facts], equation)
          {:error, _} = err -> err
        end
      [token | _] -> {:error, {:expected_open_paren, token}}
    end
  end

  # Equation: field = expr (e.g., fahrenheit = celsius * 9 / 5 + 32)
  defp parse_relation_body([{:identifier, meta, lhs}, {:operator, _, :equals} | rest], facts, _equation) do
    case parse_solver_expr(rest) do
      {:ok, rhs, rest} ->
        eq = %AST.RelationEquation{lhs: lhs, rhs: rhs, meta: meta}
        parse_relation_body(rest, facts, eq)
      {:error, _} = err -> err
    end
  end

  defp parse_relation_body([token | _], _facts, _eq), do: {:error, {:unexpected_in_relation, token}}

  # Parse arithmetic expression for solver equations
  # Handles: ref OP ref, ref OP num, num OP ref, with left-to-right chaining
  defp parse_solver_expr(tokens) do
    case parse_solver_atom(tokens) do
      {:ok, left, rest} -> parse_solver_chain(left, rest)
      err -> err
    end
  end

  defp parse_solver_chain(left, [{:operator, _, op} | rest]) when op in [:plus, :minus, :star, :slash] do
    case parse_solver_atom(rest) do
      {:ok, right, rest} ->
        op_name = case op do
          :plus -> :add
          :minus -> :sub
          :star -> :mul
          :slash -> :div
        end
        parse_solver_chain({op_name, left, right}, rest)
      err -> err
    end
  end
  defp parse_solver_chain(expr, rest), do: {:ok, expr, rest}

  defp parse_solver_atom([{:identifier, _, name} | rest]), do: {:ok, {:ref, name}, rest}
  defp parse_solver_atom([{:integer, _, n} | rest]), do: {:ok, n, rest}
  defp parse_solver_atom([token | _]), do: {:error, {:expected_solver_atom, token}}

  defp parse_fact_fields([{:delimiter, _, :close_paren} | rest], acc) do
    {:ok, Enum.reverse(acc), rest}
  end

  defp parse_fact_fields([{:delimiter, _, :comma} | rest], acc) do
    parse_fact_field(rest, acc)
  end

  defp parse_fact_fields(tokens, []) do
    parse_fact_field(tokens, [])
  end

  # name: value (atom, integer, or expression like 64 * :t1)
  defp parse_fact_field([{:identifier, _, name}, {:delimiter, _, :colon} | rest], acc) do
    case parse_simple_expr(rest) do
      {:ok, expr, rest} -> parse_fact_fields(rest, [{name, expr} | acc])
      {:error, _} = err -> err
    end
  end

  defp parse_simple_expr([{:integer, _, left}, {:operator, _, :star}, {:atom, _, right} | rest]) do
    {:ok, {:multiply, {:integer, left}, {:atom, right}}, rest}
  end

  defp parse_simple_expr([{:atom, _, value} | rest]), do: {:ok, {:atom, value}, rest}
  defp parse_simple_expr([{:integer, _, value} | rest]), do: {:ok, {:integer, value}, rest}
  defp parse_simple_expr([{:identifier, _, name} | rest]), do: {:ok, {:var, name}, rest}
  defp parse_simple_expr([token | _]), do: {:error, {:expected_expr, token}}

  # --- Extern Block ---

  defp parse_extern_block([{:keyword, meta, :extern}, {:keyword, _, :gleam}, {:keyword, _, :do} | rest]) do
    case parse_gleam_extern_decls(rest, []) do
      {:ok, decls, rest} ->
        {:ok, %AST.ExternBlock{declarations: decls, meta: meta}, rest}
      {:error, _} = err -> err
    end
  end

  defp parse_extern_block([{:keyword, meta, :extern}, {:keyword, _, :do} | rest]) do
    case parse_extern_decls(rest, []) do
      {:ok, decls, rest} ->
        {:ok, %AST.ExternBlock{declarations: decls, meta: meta}, rest}
      {:error, _} = err -> err
    end
  end

  # --- Gleam extern declarations ---
  # vordb/counter.function(args) :: type

  defp parse_gleam_extern_decls([{:keyword, _, :end} | rest], acc) do
    {:ok, Enum.reverse(acc), rest}
  end

  defp parse_gleam_extern_decls([{:identifier, meta, first_seg} | rest], acc) do
    case collect_gleam_module_path([first_seg], rest) do
      {:ok, mod_atom, func, [{:delimiter, _, :open_paren} | rest]} ->
        case parse_typed_fields_paren(rest, []) do
          {:ok, args, [{:operator, _, :double_colon} | rest]} ->
            case parse_return_type(rest) do
              {:ok, ret_type, rest} ->
                decl = %AST.ExternDecl{module: {:gleam_mod, mod_atom}, function: func, args: args, return_type: ret_type, meta: meta}
                parse_gleam_extern_decls(rest, [decl | acc])
              {:error, _} = err -> err
            end
          {:ok, _args, [token | _]} -> {:error, {:expected_double_colon, token}}
          {:error, _} = err -> err
        end
      {:error, _} = err -> err
    end
  end

  # Collect a Gleam module path: vordb/counter/sub.function
  # Segments separated by / (slash operator), ends with .function
  defp collect_gleam_module_path(segments, [{:operator, _, :slash}, {:identifier, _, next} | rest]) do
    collect_gleam_module_path(segments ++ [next], rest)
  end
  defp collect_gleam_module_path(segments, [{:operator, _, :dot}, {:identifier, _, func} | rest]) do
    mod_str = segments |> Enum.map(&Atom.to_string/1) |> Enum.join("@")
    {:ok, String.to_atom(mod_str), func, rest}
  end
  defp collect_gleam_module_path(_segments, [token | _]), do: {:error, {:expected_gleam_path, token}}

  # --- Regular extern declarations ---

  defp parse_extern_decls([{:keyword, _, :end} | rest], acc) do
    {:ok, Enum.reverse(acc), rest}
  end

  # Elixir or Erlang module: Mod.Sub.function(args) :: return_type
  defp parse_extern_decls([{:identifier, meta, first_seg} | rest], acc) do
    case collect_dotted_name([first_seg], rest) do
      {:ok, segments, func, [{:delimiter, _, :open_paren} | rest]} ->
        mod = case segments do
          [:Erlang, erl_mod] -> {:erlang_mod, Atom.to_string(erl_mod)}
          _ -> Enum.join(Enum.map(segments, &Atom.to_string/1), ".")
        end
        case parse_typed_fields_paren(rest, []) do
          {:ok, args, [{:operator, _, :double_colon} | rest]} ->
            case parse_return_type(rest) do
              {:ok, ret_type, rest} ->
                decl = %AST.ExternDecl{module: mod, function: func, args: args, return_type: ret_type, meta: meta}
                parse_extern_decls(rest, [decl | acc])
              {:error, _} = err -> err
            end
          {:ok, _args, [token | _]} -> {:error, {:expected_double_colon, token}}
          {:error, _} = err -> err
        end
      {:error, _} = err -> err
    end
  end

  # Erlang module: :mod.function(args) :: return_type
  defp parse_extern_decls([{:atom, meta, mod}, {:operator, _, :dot},
                            {:identifier, _, func}, {:delimiter, _, :open_paren} | rest], acc) do
    case parse_typed_fields_paren(rest, []) do
      {:ok, args, [{:operator, _, :double_colon} | rest]} ->
        case parse_return_type(rest) do
          {:ok, ret_type, rest} ->
            decl = %AST.ExternDecl{module: {:erlang_mod, mod}, function: func, args: args, return_type: ret_type, meta: meta}
            parse_extern_decls(rest, [decl | acc])
          {:error, _} = err -> err
        end
      {:ok, _args, [token | _]} -> {:error, {:expected_double_colon, token}}
      {:error, _} = err -> err
    end
  end

  defp parse_extern_decls([token | _], _acc), do: {:error, {:unexpected_in_extern, token}}

  # Collect segments of a dotted name: A.B.C.func -> {[:A, :B, :C], :func}
  defp collect_dotted_name(segments, [{:operator, _, :dot}, {:identifier, _, next} | rest]) do
    # Could be more segments or this could be the function name
    case rest do
      [{:operator, _, :dot} | _] ->
        collect_dotted_name(segments ++ [next], rest)
      [{:delimiter, _, :open_paren} | _] ->
        # next is the function name
        {:ok, segments, next, rest}
      _ ->
        # next is the function name
        {:ok, segments, next, rest}
    end
  end

  defp collect_dotted_name(_segments, [token | _]), do: {:error, {:expected_dot, token}}

  # Return type: identifier, or {:ok, type} | {:error, type} union
  defp parse_return_type([{:identifier, _, type} | rest]) do
    {:ok, type, rest}
  end

  defp parse_return_type([{:delimiter, _, :open_brace} | _] = tokens) do
    # Parse tuple type like {:ok, term} | {:error, term}
    case parse_return_type_union(tokens, []) do
      {:ok, types, rest} -> {:ok, {:union, types}, rest}
      {:error, _} = err -> err
    end
  end

  defp parse_return_type([token | _]), do: {:error, {:expected_return_type, token}}

  defp parse_return_type_union([{:delimiter, _, :open_brace} | rest], acc) do
    case skip_until_close_brace(rest, []) do
      {:ok, _inner, rest} ->
        # Store as raw token representation for now
        type_entry = :tuple_type
        case rest do
          [{:delimiter, _, :pipe} | rest] -> parse_return_type_union(rest, [type_entry | acc])
          _ -> {:ok, Enum.reverse([type_entry | acc]), rest}
        end
      {:error, _} = err -> err
    end
  end

  defp parse_return_type_union(tokens, []) do
    parse_return_type(tokens)
    |> case do
      {:ok, type, rest} -> {:ok, type, rest}
      err -> err
    end
  end

  defp skip_until_close_brace([{:delimiter, _, :close_brace} | rest], acc) do
    {:ok, Enum.reverse(acc), rest}
  end

  defp skip_until_close_brace([t | rest], acc) do
    skip_until_close_brace(rest, [t | acc])
  end

  defp skip_until_close_brace([], _acc), do: {:error, :unexpected_eof}

  # --- Safety ---

  # --- Invariant (generic — maps to Safety AST node) ---

  defp parse_invariant([{:keyword, meta, :invariant}, {:string, _, name} | rest]) do
    case rest do
      [{:keyword, _, tier}, {:keyword, _, :do} | rest] when tier in [:proven, :checked, :monitored] ->
        case skip_until_end(rest) do
          {:ok, body_tokens, rest} ->
            {:ok, %AST.Safety{name: name, tier: tier, body: body_tokens, meta: meta}, rest}
          {:error, _} = err -> err
        end
      [token | _] -> {:error, {:expected_tier, token}}
    end
  end

  # --- Safety ---

  defp parse_safety([{:keyword, meta, :safety}, {:string, _, name} | rest]) do
    case rest do
      [{:keyword, _, tier}, {:keyword, _, :do} | rest] when tier in [:proven, :checked, :monitored] ->
        case skip_until_end(rest) do
          {:ok, body_tokens, rest} ->
            {:ok, %AST.Safety{name: name, tier: tier, body: body_tokens, meta: meta}, rest}
          {:error, _} = err -> err
        end
      [token | _] -> {:error, {:expected_tier, token}}
    end
  end

  # --- Liveness ---

  defp parse_liveness([{:keyword, meta, :liveness}, {:string, _, name} | rest]) do
    case rest do
      # monitored(within: EXPR) do ... end
      [{:keyword, _, :monitored}, {:delimiter, _, :open_paren},
       {:identifier, _, :within}, {:delimiter, _, :colon} | rest] ->
        case parse_timeout_expr(rest) do
          {:ok, timeout_expr, [{:delimiter, _, :close_paren}, {:keyword, _, :do} | rest]} ->
            case skip_until_end(rest) do
              {:ok, body_tokens, rest} ->
                {:ok, %AST.Liveness{name: name, tier: :monitored, timeout_expr: timeout_expr, body: body_tokens, meta: meta}, rest}
              {:error, _} = err -> err
            end
          {:ok, _, [token | _]} -> {:error, {:expected_close_paren, token}}
          {:error, _} = err -> err
        end

      # Simple: tier do ... end
      [{:keyword, _, tier}, {:keyword, _, :do} | rest] when tier in [:proven, :checked, :monitored] ->
        case skip_until_end(rest) do
          {:ok, body_tokens, rest} ->
            {:ok, %AST.Liveness{name: name, tier: tier, body: body_tokens, meta: meta}, rest}
          {:error, _} = err -> err
        end

      [token | _] -> {:error, {:expected_tier, token}}
    end
  end

  defp parse_timeout_expr([{:integer, _, value} | rest]), do: {:ok, {:integer, value}, rest}
  defp parse_timeout_expr([{:identifier, _, name} | rest]), do: {:ok, {:param, name}, rest}
  defp parse_timeout_expr([token | _]), do: {:error, {:expected_timeout_expr, token}}

  # --- Resilience ---

  defp parse_resilience([{:keyword, meta, :resilience}, {:keyword, _, :do} | rest]) do
    case parse_resilience_handlers(rest, []) do
      {:ok, handlers, rest} ->
        {:ok, %AST.Resilience{handlers: handlers, meta: meta}, rest}
      {:error, _} = err -> err
    end
  end

  defp parse_resilience_handlers([{:keyword, _, :end} | rest], acc) do
    {:ok, Enum.reverse(acc), rest}
  end

  defp parse_resilience_handlers([{:identifier, meta, :on_invariant_violation},
                                   {:delimiter, _, :open_paren}, {:string, _, name},
                                   {:delimiter, _, :close_paren}, {:operator, _, :arrow} | rest], acc) do
    case parse_resilience_actions(rest, []) do
      {:ok, actions, rest} ->
        handler = %AST.ResilienceHandler{invariant_name: name, actions: actions, meta: meta}
        parse_resilience_handlers(rest, [handler | acc])
      {:error, _} = err -> err
    end
  end

  defp parse_resilience_handlers([{:identifier, _, :on_crash}, {:operator, _, :arrow} | rest], acc) do
    case skip_resilience_action_line(rest) do
      {:ok, rest} -> parse_resilience_handlers(rest, acc)
      {:error, _} = err -> err
    end
  end

  defp parse_resilience_handlers([token | _], _acc), do: {:error, {:unexpected_in_resilience, token}}

  defp parse_resilience_actions([{:keyword, _, :transition} | rest], acc) do
    case parse_transition(rest, nil) do
      {:ok, trans, rest} ->
        case rest do
          [{:delimiter, _, :comma} | rest] -> parse_resilience_actions(rest, [trans | acc])
          _ -> parse_resilience_actions(rest, [trans | acc])
        end
      {:error, _} = err -> err
    end
  end

  defp parse_resilience_actions([{:keyword, _, :emit} | rest], acc) do
    case parse_emit(rest, nil) do
      {:ok, emit, rest} ->
        case rest do
          [{:delimiter, _, :comma} | rest] -> parse_resilience_actions(rest, [emit | acc])
          _ -> parse_resilience_actions(rest, [emit | acc])
        end
      {:error, _} = err -> err
    end
  end

  defp parse_resilience_actions([{:keyword, meta, :broadcast}, {:delimiter, _, :open_brace}, {:atom, _, tag} | rest], acc) do
    case parse_binding_fields(rest, []) do
      {:ok, fields, rest} ->
        node = %AST.Broadcast{tag: tag, fields: fields, meta: meta}
        parse_resilience_actions(rest, [node | acc])
      {:error, _} = err -> err
    end
  end

  defp parse_resilience_actions([{:keyword, meta, :send}, {:atom, _, target} | rest], acc) do
    case rest do
      [{:delimiter, _, :open_brace}, {:atom, _, tag} | rest] ->
        case parse_binding_fields(rest, []) do
          {:ok, fields, rest} ->
            node = %AST.Send{target: target, tag: tag, fields: fields, meta: meta}
            parse_resilience_actions(rest, [node | acc])
          {:error, _} = err -> err
        end
      [token | _] -> {:error, {:expected_send_message, token}}
    end
  end

  defp parse_resilience_actions([{:keyword, meta, :send}, {:identifier, _, target} | rest], acc) do
    case rest do
      [{:delimiter, _, :open_brace}, {:atom, _, tag} | rest] ->
        case parse_binding_fields(rest, []) do
          {:ok, fields, rest} ->
            node = %AST.Send{target: {:var, target}, tag: tag, fields: fields, meta: meta}
            parse_resilience_actions(rest, [node | acc])
          {:error, _} = err -> err
        end
      [token | _] -> {:error, {:expected_send_message, token}}
    end
  end

  defp parse_resilience_actions(tokens, acc), do: {:ok, Enum.reverse(acc), tokens}

  defp skip_resilience_action_line([{:keyword, _, :end} | _] = rest), do: {:ok, rest}
  defp skip_resilience_action_line([{:identifier, _, :on_invariant_violation} | _] = rest), do: {:ok, rest}
  defp skip_resilience_action_line([{:identifier, _, :on_crash} | _] = rest), do: {:ok, rest}
  defp skip_resilience_action_line([_ | rest]), do: skip_resilience_action_line(rest)
  defp skip_resilience_action_line([]), do: {:error, :unexpected_eof}

  # --- Utilities ---

  # Skip tokens until matching `end`, tracking nesting
  defp skip_until_end(tokens), do: skip_until_end(tokens, [], 0)

  defp skip_until_end([{:keyword, _, :end} | rest], acc, 0) do
    {:ok, Enum.reverse(acc), rest}
  end

  defp skip_until_end([{:keyword, _, :do} = t | rest], acc, depth) do
    skip_until_end(rest, [t | acc], depth + 1)
  end

  defp skip_until_end([{:keyword, _, :end} = t | rest], acc, depth) do
    skip_until_end(rest, [t | acc], depth - 1)
  end

  defp skip_until_end([t | rest], acc, depth) do
    skip_until_end(rest, [t | acc], depth)
  end

  defp skip_until_end([], _acc, _depth), do: {:error, :unexpected_eof}
end
