defmodule Vor.Compiler do
  @moduledoc """
  Orchestrates the full Vor compilation pipeline:
  source → tokens → AST → IR → analysis → Erlang forms → BEAM binary.
  """

  def compile_string(source, opts \\ []) do
    with {:ok, tokens} <- Vor.Lexer.tokenize(source),
         {:ok, ast} <- Vor.Parser.parse(tokens),
         {:ok, ir} <- Vor.Lowering.lower(ast),
         {:ok, _warnings} <- Vor.Analysis.ProtocolChecker.check(ir),
         {:ok, forms} <- Vor.Codegen.Erlang.generate(ir),
         {:ok, module, binary, compile_warnings} <- Vor.Codegen.Beam.compile(forms, opts) do
      {:ok, %{module: module, binary: binary, warnings: compile_warnings, ir: ir, forms: forms}}
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
end
