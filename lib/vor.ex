defmodule Vor do
  @moduledoc """
  Vor — a constrained, BEAM-native, declarative language for agent orchestration.

  Relations for knowledge, handlers for effects. The spec is the program.
  """

  defdelegate compile(source, opts \\ []), to: Vor.Compiler, as: :compile_string
  defdelegate compile_file(path, opts \\ []), to: Vor.Compiler
  defdelegate compile_and_load(source, opts \\ []), to: Vor.Compiler
end
