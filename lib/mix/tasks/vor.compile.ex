defmodule Mix.Tasks.Vor.Compile do
  use Mix.Task

  @shortdoc "Compile a .vor file with optional trace output"

  @moduledoc """
  Compiles a `.vor` source file to a BEAM module.

  ## Usage

      mix vor.compile path/to/agent.vor
      mix vor.compile path/to/agent.vor --trace

  ## Options

    * `--trace` - Print detailed compilation trace showing each pipeline stage
  """

  def run(args) do
    Mix.Task.run("app.start")

    {opts, files, _} = OptionParser.parse(args, switches: [trace: :boolean])
    trace = Keyword.get(opts, :trace, false)

    case files do
      [] ->
        IO.puts("Usage: mix vor.compile <file.vor> [--trace]")
        System.halt(1)

      [file | _] ->
        source = File.read!(file)

        case Vor.Compiler.compile_string(source, trace: trace) do
          {:ok, result} ->
            unless trace do
              IO.puts("✓ Compiled: #{result.module}")
            end

          {:error, reason} ->
            IO.puts("✗ Error: #{inspect(reason)}")
            System.halt(1)
        end
    end
  end
end
