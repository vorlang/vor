defmodule Mix.Tasks.Vor.Coverage do
  use Mix.Task

  @shortdoc "Show project-level verification coverage"

  @moduledoc """
  Aggregates the spec inventory (see `mix vor.surface`) into a verification
  posture report: how much of the project's declared surface is defended by
  safety/liveness invariants, constraints, backpressure, and chaos — and where
  the gaps are.

  ## Usage

      mix vor.coverage                 # all .vor in lib/ + examples/, text
      mix vor.coverage --format json   # JSON for CI quality gates
      mix vor.coverage --file examples # a specific file or directory

  Gaps are informational, not errors. CI can enforce thresholds against the
  JSON output. Read-only: no verification or chaos is run.
  """

  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, _} =
      OptionParser.parse(args, strict: [format: :string, file: :string])

    format = opts[:format] || "text"

    files =
      opts[:file]
      |> discover_files()
      |> Enum.map(&surface_file/1)
      |> Enum.reject(&is_nil/1)

    coverage = Vor.Coverage.analyze(files)

    case format do
      "text" -> Mix.shell().info(Vor.Coverage.format_text(coverage, project_name()))
      "json" -> Mix.shell().info(Vor.Coverage.format_json(coverage))
      other -> Mix.raise("Unknown --format #{inspect(other)} (expected text or json)")
    end
  end

  defp discover_files(nil) do
    (Path.wildcard("lib/**/*.vor") ++ Path.wildcard("examples/**/*.vor"))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp discover_files(path) do
    cond do
      File.dir?(path) -> path |> Path.join("**/*.vor") |> Path.wildcard() |> Enum.sort()
      true -> [path]
    end
  end

  defp surface_file(path) do
    with {:ok, source} <- File.read(path),
         {:ok, map} <- Vor.Surface.extract_source(source, path) do
      map
    else
      {:error, reason} ->
        Mix.shell().error("Skipping #{path}: #{inspect(reason)}")
        nil
    end
  end

  defp project_name, do: to_string(Mix.Project.config()[:app] || "vor")
end
