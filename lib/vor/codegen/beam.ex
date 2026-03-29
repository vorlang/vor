defmodule Vor.Codegen.Beam do
  @moduledoc """
  Compiles Erlang abstract format to BEAM bytecode using :compile.forms/2.
  """

  def compile(forms, opts \\ []) do
    compiler_opts = [:return_errors, :return_warnings | opts]

    case :compile.forms(forms, compiler_opts) do
      {:ok, module, binary, warnings} ->
        {:ok, module, binary, warnings}

      {:ok, module, binary} ->
        {:ok, module, binary, []}

      {:error, errors, warnings} ->
        {:error, errors, warnings}
    end
  end

  def load(module, binary) do
    case :code.load_binary(module, ~c"vor_generated", binary) do
      {:module, ^module} -> {:ok, module}
      {:error, reason} -> {:error, reason}
    end
  end

  def write_beam(binary, output_dir, module) do
    filename = module |> Atom.to_string() |> String.replace(".", "_")
    path = Path.join(output_dir, "#{filename}.beam")
    File.mkdir_p!(output_dir)
    File.write!(path, binary)
    {:ok, path}
  end
end
