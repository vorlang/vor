defmodule Vor.Compiler do
  @moduledoc """
  Orchestrates the full Vor compilation pipeline:
  source → tokens → AST → IR → analysis → verification → Erlang forms → BEAM binary.
  """

  def compile_string(source, opts \\ []) do
    trace = Keyword.get(opts, :trace, false)

    if trace, do: IO.puts("\n═══ Vor Compiler Trace ═══\n")
    if trace, do: trace_source(source)

    with {:ok, tokens} <- Vor.Lexer.tokenize(source),
         _ <- (if trace, do: trace_lexer(tokens)),
         {:ok, ast} <- Vor.Parser.parse(tokens),
         _ <- (if trace, do: trace_parser(ast)),
         {:ok, ir} <- Vor.Lowering.lower(ast),
         _ <- (if trace, do: trace_lowering(ir)),
         :ok <- validate_init_handler(ir),
         {:ok, _warnings} <- Vor.Analysis.ProtocolChecker.check(ir),
         {:ok, _completeness_warnings} <- Vor.Analysis.Completeness.check(ir),
         {:ok, _type_warnings} <- Vor.Analysis.TypeChecker.check(ir),
         :ok <- verify_safety(ir),
         _ <- (if trace, do: trace_verification(ir)),
         {:ok, forms} <- Vor.Codegen.Erlang.generate(ir),
         _ <- (if trace, do: trace_codegen(ir)),
         {:ok, module, binary, compile_warnings} <- Vor.Codegen.Beam.compile(forms, opts) do
      if trace, do: trace_compile(module, binary)
      if trace, do: IO.puts("\n═══ Complete ═══")
      graph = extract_graph_from_ir(ir)
      {:ok, %{module: module, binary: binary, warnings: compile_warnings, ir: ir, forms: forms, graph: graph}}
    end
  end

  def compile_file(path, opts \\ []) do
    source = File.read!(path)
    compile_string(source, opts)
  end

  def compile_and_load(source, opts \\ []) do
    with {:ok, result} <- compile_string(source, opts),
         {:ok, _module} <- Vor.Codegen.Beam.load(result.module, result.binary) do
      {:ok, result}
    end
  end

  @doc """
  Extract the state graph from a .vor source string.
  """
  def extract_graph(source) do
    with {:ok, tokens} <- Vor.Lexer.tokenize(source),
         {:ok, ast} <- Vor.Parser.parse(tokens),
         {:ok, ir} <- Vor.Lowering.lower(ast) do
      case Vor.Graph.extract(ir) do
        {:ok, graph} -> {:ok, graph}
        :no_graph -> {:error, :no_state_machine}
      end
    end
  end

  defp extract_graph_from_ir(ir) do
    case Vor.Graph.extract(ir) do
      {:ok, graph} -> graph
      :no_graph -> nil
    end
  end

  defp verify_safety(ir) do
    case Vor.Graph.extract(ir) do
      {:ok, graph} ->
        # Verify proven safety invariants using body tokens
        safety_invariants = get_safety_bodies(ir)

        results = Enum.map(safety_invariants, fn {name, body_tokens} ->
          result = Vor.Verification.Safety.verify_body(body_tokens, graph, ir)
          {name, result}
        end)

        # Check for extern-gated proven invariants (fail closed: a proof
        # cannot depend on what an extern returns)
        extern_gated = Enum.filter(results, fn
          {_name, {:error, {:extern_gated_emit, _}}} -> true
          {_name, {:error, {:extern_gated_transition, _}}} -> true
          _ -> false
        end)

        unsupported = Enum.filter(results, fn
          {_name, {:error, {:unsupported_invariant, _}}} -> true
          _ -> false
        end)

        cond do
          extern_gated != [] ->
            [{name, {:error, kind_info}} | _] = extern_gated
            {:error, %{type: :extern_gated_invariant, name: name,
                        message: format_extern_gated_message(name, kind_info)}}

          unsupported != [] ->
            [{name, {:error, {:unsupported_invariant, msg}}} | _] = unsupported
            {:error, %{type: :unsupported_invariant, name: name, message: msg}}

          true -> :ok
        end
        |> case do
          {:error, _} = err -> err
          :ok ->
            violations = Enum.filter(results, fn
              {_name, {:violated, _reason}} -> true
              _ -> false
            end)

            case violations do
              [] -> :ok
              _ ->
                error_details = Enum.map(violations, fn {name, {:violated, reason}} ->
                  %{name: name, reason: reason}
                end)
                {:error, %{type: :invariant_violation, violations: error_details}}
            end
        end

      :no_graph ->
        # No state machine — no graph-based verification to do
        :ok
    end
  end

  defp format_extern_gated_message(name, {:extern_gated_emit, %{state: state, tag: tag, handler: handler}}) do
    pat = handler.pattern.tag
    """
    Safety invariant "#{name}" cannot be proven

      In handler on {:#{pat}, ...} when #{state_field_pretty(handler)} == :#{state}:
        The emit {:#{tag}, ...} is inside a conditional whose condition
        depends on the result of an extern call. Proven invariants must be
        verifiable from Vor-visible code alone. The compiler cannot determine
        what the extern returns, so it cannot prove the invariant holds on
        all paths.

      Options:
        - Remove the extern dependency from the conditional
        - Change the invariant from 'proven' to 'monitored'
        - Restructure the handler so the prohibited emit is unreachable
          regardless of extern results
    """
  end

  defp format_extern_gated_message(name, {:extern_gated_transition, %{from: from, to: to, handler: handler}}) do
    pat = handler.pattern.tag
    """
    Safety invariant "#{name}" cannot be proven

      In handler on {:#{pat}, ...} when #{state_field_pretty(handler)} == :#{from}:
        The transition to :#{to} is inside a conditional whose condition
        depends on the result of an extern call. Proven invariants must be
        verifiable from Vor-visible code alone.

      Options:
        - Remove the extern dependency from the conditional
        - Change the invariant from 'proven' to 'monitored'
        - Restructure the handler so the prohibited transition is unreachable
          regardless of extern results
    """
  end

  defp state_field_pretty(%Vor.IR.Handler{guard: %Vor.IR.GuardExpr{field: f}}), do: f
  defp state_field_pretty(%Vor.IR.Handler{guard: %Vor.IR.CompoundGuardExpr{left: %Vor.IR.GuardExpr{field: f}}}), do: f
  defp state_field_pretty(_), do: :phase

  defp get_safety_bodies(ir) do
    ir.invariants
    |> Enum.filter(fn
      {:safety, _name, :proven, body} -> is_list(body)
      _ -> false
    end)
    |> Enum.map(fn {:safety, name, :proven, body} -> {name, body} end)
  end

  @doc """
  Compile a source with multiple agents and a system block.
  Returns `{:ok, %{agents: [...], system: system_module}}` or `{:error, ...}`.
  """
  def compile_system(source, opts \\ []) do
    with {:ok, tokens} <- Vor.Lexer.tokenize(source),
         {:ok, parsed} <- Vor.Parser.parse_multi(tokens),
         {:ok, agent_irs, system_ir} <- lower_system(parsed),
         :ok <- check_system_protocols(system_ir, agent_irs),
         {:ok, agent_results} <- compile_agents(agent_irs, opts),
         {:ok, system_result} <- compile_system_module(system_ir, agent_irs, opts) do
      {:ok, %{
        agents: agent_results,
        system: system_result,
        system_ir: system_ir
      }}
    end
  end

  def compile_system_and_load(source, opts \\ []) do
    with {:ok, result} <- compile_system(source, opts) do
      # Load all agent modules
      for {_name, agent} <- result.agents do
        Vor.Codegen.Beam.load(agent.module, agent.binary)
      end

      # Load system module
      Vor.Codegen.Beam.load(result.system.module, result.system.binary)

      {:ok, result}
    end
  end

  defp lower_system(%{agents: agent_asts, system: system_ast}) do
    # Lower each agent
    agent_irs =
      Enum.reduce(agent_asts, %{}, fn agent_ast, acc ->
        {:ok, ir} = Vor.Lowering.lower(agent_ast)
        Map.put(acc, ir.name, ir)
      end)

    system_ir = if system_ast do
      lower_system_block(system_ast, agent_irs)
    else
      nil
    end

    {:ok, agent_irs, system_ir}
  end

  defp lower_system_block(%Vor.AST.System{name: name, agents: agents, connections: connections, invariants: invariants, chaos: chaos}, agent_irs) do
    %Vor.IR.SystemIR{
      name: name,
      registry: Module.concat([Vor, System, name, Registry]),
      agents: Enum.map(agents, fn %Vor.AST.AgentInstance{name: inst_name, type: type, params: params} ->
        type_atom = if is_atom(type), do: type, else: String.to_atom(to_string(type))
        ir = Map.get(agent_irs, type_atom)
        module = if ir, do: ir.module, else: Module.concat([Vor, Agent, type_atom])
        behaviour = if ir, do: ir.behaviour, else: :gen_server

        inst_name_atom = if is_atom(inst_name), do: inst_name, else: String.to_atom(inst_name)
        params_normalized = Enum.map(params || [], fn
          {k, v} when is_atom(k) -> {k, v}
          {k, v} -> {String.to_atom(to_string(k)), v}
        end)

        %Vor.IR.AgentInstanceIR{
          name: inst_name_atom,
          module: module,
          type_name: type_atom,
          params: params_normalized,
          behaviour: behaviour
        }
      end),
      connections: Enum.map(connections, fn %Vor.AST.Connect{from: from, to: to} ->
        from_atom = if is_atom(from), do: from, else: String.to_atom(from)
        to_atom = if is_atom(to), do: to, else: String.to_atom(to)
        %{from: from_atom, to: to_atom}
      end),
      invariants: Enum.map(invariants || [], fn %Vor.AST.SystemSafety{name: n, tier: tier, body: body} ->
        %Vor.IR.SystemInvariant{name: n, tier: tier, body: body}
      end),
      chaos: lower_chaos(chaos)
    }
  end

  defp lower_chaos(nil), do: nil
  defp lower_chaos(%Vor.AST.ChaosConfig{} = c) do
    %Vor.IR.ChaosConfig{
      duration_ms: c.duration_ms,
      seed: c.seed,
      kill: c.kill,
      partition: c.partition,
      delay: c.delay,
      drop: c.drop,
      workload: c.workload,
      check: c.check
    }
  end

  defp check_system_protocols(nil, _agent_irs), do: :ok
  defp check_system_protocols(system_ir, agent_irs) do
    # Map instance names to their agent IRs
    instance_to_ir = Map.new(system_ir.agents, fn a ->
      {a.name, Map.get(agent_irs, a.type_name)}
    end)

    case Vor.Verification.Protocol.check(system_ir, instance_to_ir) do
      {:ok, _warnings} -> :ok
      {:error, errors} ->
        first = hd(errors)
        {:error, %{type: first.type, details: errors}}
    end
  end

  defp compile_agents(agent_irs, opts) do
    results = Enum.reduce_while(agent_irs, {:ok, %{}}, fn {name, ir}, {:ok, acc} ->
      with {:ok, _warnings} <- Vor.Analysis.ProtocolChecker.check(ir),
           {:ok, _completeness_warnings} <- Vor.Analysis.Completeness.check(ir),
           {:ok, _type_warnings} <- Vor.Analysis.TypeChecker.check(ir),
           :ok <- verify_safety(ir),
           {:ok, forms} <- Vor.Codegen.Erlang.generate(ir),
           {:ok, module, binary, warnings} <- Vor.Codegen.Beam.compile(forms, opts) do
        graph = extract_graph_from_ir(ir)
        result = %{module: module, binary: binary, warnings: warnings, ir: ir, graph: graph}
        {:cont, {:ok, Map.put(acc, name, result)}}
      else
        err -> {:halt, err}
      end
    end)

    results
  end

  defp compile_system_module(nil, _agent_irs, _opts), do: {:ok, nil}
  defp compile_system_module(system_ir, agent_irs, opts) do
    # Map instance names to agent IRs for the system codegen
    instance_ir_map = Map.new(system_ir.agents, fn a ->
      {a.name, Map.get(agent_irs, a.type_name)}
    end)

    case Vor.Codegen.System.generate(system_ir, instance_ir_map) do
      {:ok, forms, meta} ->
        case Vor.Codegen.Beam.compile(forms, opts) do
          {:ok, module, binary, warnings} ->
            {:ok, %{module: module, binary: binary, warnings: warnings,
                     registry: meta.registry, start_link: fn -> apply(module, :start_link, []) end}}
          err -> err
        end
      err -> err
    end
  end

  defp validate_init_handler(%Vor.IR.Agent{init_handler: nil}), do: :ok
  defp validate_init_handler(%Vor.IR.Agent{init_handler: :duplicate_init}) do
    {:error, %{type: :duplicate_init, message: "Only one 'on :init' handler allowed per agent"}}
  end
  defp validate_init_handler(%Vor.IR.Agent{init_handler: handler}) do
    # Check for forbidden actions in init handler
    forbidden = find_forbidden_init_actions(handler.actions)
    case forbidden do
      [] -> :ok
      [type | _] ->
        {:error, %{type: :invalid_init_handler,
          message: "Cannot use '#{type}' in an init handler. Init handlers run during startup before the agent is registered."}}
    end
  end

  defp find_forbidden_init_actions(actions) do
    Enum.flat_map(actions, fn
      %Vor.IR.Action{type: :emit} -> [:emit]
      %Vor.IR.Action{type: :send} -> [:send]
      %Vor.IR.Action{type: :broadcast} -> [:broadcast]
      %Vor.IR.Action{type: :conditional, data: %{then_actions: ta, else_actions: ea}} ->
        find_forbidden_init_actions(ta) ++ find_forbidden_init_actions(ea)
      _ -> []
    end)
  end

  # --- Trace helpers ---

  defp trace_source(source) do
    lines = source |> String.split("\n") |> length()
    IO.puts("[source]   #{lines} lines")
  end

  defp trace_lexer(tokens) do
    keywords = tokens
    |> Enum.filter(fn {type, _, _} -> type == :keyword end)
    |> Enum.map(fn {_, _, val} -> val end)
    |> Enum.uniq()
    |> Enum.join(", ")

    identifiers = tokens
    |> Enum.filter(fn {type, _, _} -> type == :identifier end)
    |> Enum.map(fn {_, _, val} -> val end)
    |> Enum.uniq()
    |> Enum.take(10)
    |> Enum.join(", ")

    IO.puts("[lexer]    #{length(tokens)} tokens")
    IO.puts("           keywords: #{keywords}")
    IO.puts("           identifiers: #{identifiers}")
  end

  defp trace_parser(%Vor.AST.Agent{name: name, params: params, body: body}) do
    handler_count = Enum.count(body, &match?(%Vor.AST.Handler{}, &1))
    has_protocol = Enum.any?(body, &match?(%Vor.AST.Protocol{}, &1))
    has_relations = Enum.any?(body, &match?(%Vor.AST.Relation{}, &1))
    has_safety = Enum.any?(body, &match?(%Vor.AST.Safety{}, &1))
    has_liveness = Enum.any?(body, &match?(%Vor.AST.Liveness{}, &1))
    param_str = if params && params != [], do: "(#{length(params)} params)", else: "(no params)"

    IO.puts("[parser]   agent #{name}#{param_str}")
    if has_protocol, do: IO.puts("           ├── protocol declared")
    IO.puts("           ├── handlers: #{handler_count}")
    if has_relations, do: IO.puts("           ├── relations declared")
    if has_safety, do: IO.puts("           ├── safety invariants")
    if has_liveness, do: IO.puts("           └── liveness invariants")
  end

  defp trace_lowering(%Vor.IR.Agent{} = ir) do
    handler_count = length(ir.handlers)
    data_count = length(ir.data_fields || [])
    param_count = length(ir.params || [])

    IO.puts("[lower]    target: #{ir.behaviour}")
    IO.puts("           module: #{ir.module}")
    if param_count > 0, do: IO.puts("           params: #{param_count}")
    if data_count > 0, do: IO.puts("           data fields: #{data_count}")
    if ir.state_fields != [] do
      states = ir.state_fields |> hd() |> Map.get(:values) |> Enum.join(", ")
      IO.puts("           states: #{states}")
    end
    IO.puts("           handlers: #{handler_count}")
  end

  defp trace_verification(%Vor.IR.Agent{} = ir) do
    safety_count = ir.invariants |> Enum.count(fn
      {:safety, _, :proven, _} -> true
      _ -> false
    end)
    liveness_count = ir.invariants |> Enum.count(fn
      {:liveness, _, _} -> true
      _ -> false
    end)

    IO.puts("[verify]   safety invariants: #{safety_count} (all proven)")
    if liveness_count > 0, do: IO.puts("           liveness monitors: #{liveness_count}")
  end

  defp trace_codegen(%Vor.IR.Agent{} = ir) do
    exports = case ir.behaviour do
      :gen_server -> "init/1, handle_call/3, handle_cast/2"
      :gen_statem -> "init/1, callback_mode/0, handle_event/4"
    end
    IO.puts("[codegen]  Erlang abstract format generated")
    IO.puts("           exports: #{exports}")
  end

  defp trace_compile(module, binary) do
    size_kb = Float.round(byte_size(binary) / 1024, 1)
    IO.puts("[compile]  ✓ BEAM binary: #{module} (#{size_kb} KB)")
  end
end
