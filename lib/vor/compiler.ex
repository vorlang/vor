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
end
