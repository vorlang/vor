defmodule Mix.Tasks.Vor.Graph do
  @moduledoc """
  Extract and display the state graph from a .vor file.

  ## Usage

      mix vor.graph examples/circuit_breaker.vor
      mix vor.graph examples/circuit_breaker.vor --mermaid
  """

  use Mix.Task

  @shortdoc "Extract and display the state graph from a .vor file"

  def run(args) do
    {opts, rest, _} = OptionParser.parse(args, switches: [mermaid: :boolean])

    file = case rest do
      [f | _] -> f
      [] ->
        Mix.shell().error("Usage: mix vor.graph <file.vor> [--mermaid]")
        System.halt(1)
    end

    source = File.read!(file)

    case Vor.Compiler.extract_graph(source) do
      {:ok, graph} ->
        if opts[:mermaid] do
          Mix.shell().info(Vor.Graph.to_mermaid(graph))
        else
          Mix.shell().info(Vor.Graph.to_text(graph))
        end

      {:error, :no_state_machine} ->
        Mix.shell().error("#{file}: agent has no state declaration (gen_server, not gen_statem)")
    end
  end
end
