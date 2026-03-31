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

  # --- Agent ---

  defp parse_agent([{:keyword, meta, :agent}, {:identifier, _, name}, {:keyword, _, :do} | rest]) do
    case parse_declarations(rest, []) do
      {:ok, body, rest} ->
        {:ok, %AST.Agent{name: name, body: body, meta: meta}, rest}
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
    case parse_protocol_entries(rest, [], []) do
      {:ok, accepts, emits, rest} ->
        {:ok, %AST.Protocol{accepts: accepts, emits: emits, meta: meta}, rest}
      {:error, _} = err -> err
    end
  end

  defp parse_protocol_entries([{:keyword, _, :end} | rest], accepts, emits) do
    {:ok, Enum.reverse(accepts), Enum.reverse(emits), rest}
  end

  defp parse_protocol_entries([{:keyword, _, :accepts} | rest], accepts, emits) do
    case parse_message_spec(rest) do
      {:ok, spec, rest} -> parse_protocol_entries(rest, [spec | accepts], emits)
      {:error, _} = err -> err
    end
  end

  defp parse_protocol_entries([{:keyword, _, :emits} | rest], accepts, emits) do
    case parse_message_spec(rest) do
      {:ok, spec, rest} -> parse_protocol_entries(rest, accepts, [spec | emits])
      {:error, _} = err -> err
    end
  end

  defp parse_protocol_entries([token | _], _a, _e), do: {:error, {:unexpected_in_protocol, token}}
  defp parse_protocol_entries([], _a, _e), do: {:error, :unexpected_eof}

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

  # field: Var
  defp parse_binding_field([{:identifier, _, field}, {:delimiter, _, :colon}, {:identifier, _, var} | rest], acc) do
    parse_binding_fields(rest, [{field, {:var, var}} | acc])
  end

  # field: :atom_value
  defp parse_binding_field([{:identifier, _, field}, {:delimiter, _, :colon}, {:atom, _, value} | rest], acc) do
    parse_binding_fields(rest, [{field, {:atom, value}} | acc])
  end

  defp parse_binding_field([token | _], _acc), do: {:error, {:expected_binding, token}}

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

  # var = Mod.Sub.function(...) — extern call with binding (Elixir module)
  defp parse_handler_body([{:identifier, meta, bind_var}, {:operator, _, :equals},
                            {:identifier, _, first_seg}, {:operator, _, :dot} | rest], acc) do
    case collect_dotted_name([first_seg], [{:operator, nil, :dot} | rest]) do
      {:ok, segments, func, [{:delimiter, _, :open_paren} | rest]} ->
        mod = Enum.join(Enum.map(segments, &Atom.to_string/1), ".")
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

  # Mod.Sub.function(...) — extern call without binding (Elixir module)
  defp parse_handler_body([{:identifier, meta, first_seg}, {:operator, _, :dot} | rest], acc) do
    case collect_dotted_name([first_seg], [{:operator, nil, :dot} | rest]) do
      {:ok, segments, func, [{:delimiter, _, :open_paren} | rest]} ->
        mod = Enum.join(Enum.map(segments, &Atom.to_string/1), ".")
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

  defp parse_extern_arg_field([token | _], _acc), do: {:error, {:expected_extern_arg, token}}

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

  # --- Transition: transition field: :value ---

  defp parse_transition([{:identifier, _, field}, {:delimiter, _, :colon}, {:atom, _, value} | rest], meta) do
    {:ok, %AST.Transition{field: field, value: value, meta: meta}, rest}
  end

  defp parse_transition([token | _], _meta), do: {:error, {:expected_transition, token}}

  # --- State Declaration: state field: :v1 | :v2 | :v3 ---

  defp parse_state_decl([{:keyword, meta, :state} | rest]) do
    case rest do
      [{:identifier, _, field}, {:delimiter, _, :colon} | rest] ->
        case parse_type_union(rest, []) do
          {:ok, types, rest} ->
            {:ok, %AST.StateDecl{field: field, type_union: types, meta: meta}, rest}
          {:error, _} = err -> err
        end
      [token | _] -> {:error, {:expected_state_field, token}}
    end
  end

  defp parse_type_union([{:atom, _, value} | rest], acc) do
    case rest do
      [{:delimiter, _, :pipe} | rest] -> parse_type_union(rest, [value | acc])
      _ -> {:ok, Enum.reverse([value | acc]), rest}
    end
  end

  defp parse_type_union([token | _], _acc), do: {:error, {:expected_type, token}}

  # --- Relation ---

  defp parse_relation([{:keyword, meta, :relation}, {:identifier, _, name}, {:delimiter, _, :open_paren} | rest]) do
    case parse_typed_fields_paren(rest, []) do
      {:ok, params, [{:keyword, _, :do} | rest]} ->
        case parse_facts(rest, []) do
          {:ok, facts, rest} ->
            {:ok, %AST.Relation{name: name, params: params, facts: facts, meta: meta}, rest}
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

  defp parse_facts([{:keyword, _, :end} | rest], acc), do: {:ok, Enum.reverse(acc), rest}

  defp parse_facts([{:keyword, _, :fact} | rest], acc) do
    case rest do
      [{:delimiter, _, :open_paren} | rest] ->
        case parse_fact_fields(rest, []) do
          {:ok, fields, rest} -> parse_facts(rest, [%AST.Fact{fields: fields} | acc])
          {:error, _} = err -> err
        end
      [token | _] -> {:error, {:expected_open_paren, token}}
    end
  end

  defp parse_facts([token | _], _acc), do: {:error, {:unexpected_in_relation, token}}

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
  defp parse_simple_expr([token | _]), do: {:error, {:expected_expr, token}}

  # --- Extern Block ---

  defp parse_extern_block([{:keyword, meta, :extern}, {:keyword, _, :do} | rest]) do
    case parse_extern_decls(rest, []) do
      {:ok, decls, rest} ->
        {:ok, %AST.ExternBlock{declarations: decls, meta: meta}, rest}
      {:error, _} = err -> err
    end
  end

  defp parse_extern_decls([{:keyword, _, :end} | rest], acc) do
    {:ok, Enum.reverse(acc), rest}
  end

  # Elixir module: Mod.Sub.function(args) :: return_type
  defp parse_extern_decls([{:identifier, meta, first_seg} | rest], acc) do
    case collect_dotted_name([first_seg], rest) do
      {:ok, segments, func, [{:delimiter, _, :open_paren} | rest]} ->
        mod = Enum.join(Enum.map(segments, &Atom.to_string/1), ".")
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
      [{:keyword, _, tier}, {:keyword, _, :do} | rest] when tier in [:proven, :checked, :monitored] ->
        case skip_until_end(rest) do
          {:ok, body_tokens, rest} ->
            {:ok, %AST.Liveness{name: name, tier: tier, body: body_tokens, meta: meta}, rest}
          {:error, _} = err -> err
        end
      [token | _] -> {:error, {:expected_tier, token}}
    end
  end

  # --- Resilience ---

  defp parse_resilience([{:keyword, meta, :resilience}, {:keyword, _, :do} | rest]) do
    case skip_until_end(rest) do
      {:ok, body_tokens, rest} ->
        {:ok, %AST.Resilience{handlers: body_tokens, meta: meta}, rest}
      {:error, _} = err -> err
    end
  end

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
