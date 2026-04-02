defmodule Vor.Compiler do
  @moduledoc """
  Orchestrates the full Vor compilation pipeline:
  source → tokens → AST → IR → analysis → verification → Erlang forms → BEAM binary.
  """

  def compile_string(source, opts \\ []) do
    with {:ok, tokens} <- Vor.Lexer.tokenize(source),
         {:ok, ast} <- Vor.Parser.parse(tokens),
         {:ok, ir} <- Vor.Lowering.lower(ast),
         {:ok, _warnings} <- Vor.Analysis.ProtocolChecker.check(ir),
         :ok <- verify_safety(ir),
         {:ok, forms} <- Vor.Codegen.Erlang.generate(ir),
         {:ok, module, binary, compile_warnings} <- Vor.Codegen.Beam.compile(forms, opts) do
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
          result = Vor.Verification.Safety.verify_body(body_tokens, graph)
          {name, result}
        end)

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

      :no_graph ->
        # No state machine — no graph-based verification to do
        :ok
    end
  end

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
    agent_irs = Enum.reduce_while(agent_asts, {:ok, %{}}, fn agent_ast, {:ok, acc} ->
      case Vor.Lowering.lower(agent_ast) do
        {:ok, ir} ->
          name = ir.name
          {:cont, {:ok, Map.put(acc, name, ir)}}
        {:error, _} = err ->
          {:halt, err}
      end
    end)

    case agent_irs do
      {:ok, irs} ->
        system_ir = if system_ast do
          lower_system_block(system_ast, irs)
        else
          nil
        end
        {:ok, irs, system_ir}

      {:error, _} = err -> err
    end
  end

  defp lower_system_block(%Vor.AST.System{name: name, agents: agents, connections: connections}, agent_irs) do
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
      end)
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
end
