defmodule Mix.Tasks.Vor.Surface do
  use Mix.Task

  @shortdoc "Emit a queryable inventory of declared Vor specs"

  @moduledoc """
  Parses `.vor` files and emits a structured inventory of everything they
  declare — agents, states, protocols, invariants, backpressure, externs, and
  systems. Read-only: no verification is run.

  ## Usage

      mix vor.surface                          # all .vor files, JSON to stdout
      mix vor.surface --file examples/lock.vor # a single file
      mix vor.surface --format text            # human-readable

  By default it scans `lib/` and `examples/` for `.vor` files. The JSON output
  is machine-readable for dashboards, CI quality gates, and external tooling.
  """

  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, _} =
      OptionParser.parse(args, strict: [file: :string, format: :string])

    files =
      case opts[:file] do
        nil -> discover_files()
        path -> [path]
      end

    format = opts[:format] || "json"

    file_maps =
      files
      |> Enum.map(&surface_file/1)
      |> Enum.reject(&is_nil/1)

    inventory = %{
      project: to_string(Mix.Project.config()[:app] || "vor"),
      files: file_maps
    }

    case format do
      "text" -> IO.puts(render_text(inventory))
      "json" -> IO.puts(Jason.encode!(inventory, pretty: true))
      other -> Mix.raise("Unknown --format #{inspect(other)} (expected json or text)")
    end
  end

  defp discover_files do
    (Path.wildcard("lib/**/*.vor") ++ Path.wildcard("examples/**/*.vor"))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp surface_file(path) do
    case File.read(path) do
      {:ok, source} ->
        case Vor.Surface.extract_source(source, path) do
          {:ok, map} ->
            map

          {:error, reason} ->
            Mix.shell().error("Skipping #{path}: parse error #{inspect(reason)}")
            nil
        end

      {:error, reason} ->
        Mix.shell().error("Skipping #{path}: #{:file.format_error(reason)}")
        nil
    end
  end

  # ---------------------------------------------------------------------------
  # Text rendering
  # ---------------------------------------------------------------------------

  defp render_text(%{files: files}) do
    files
    |> Enum.map(&render_file/1)
    |> Enum.join("\n")
  end

  defp render_file(%{file: file, agents: agents, systems: systems}) do
    [file]
    |> Kernel.++(Enum.map(agents, &render_agent/1))
    |> Kernel.++(Enum.map(systems, &render_system/1))
    |> Enum.join("\n")
  end

  defp render_agent(a) do
    states =
      a.states
      |> Enum.map(fn s ->
        label =
          case s do
            %{type: "enum", values: vs} -> "#{s.name} (:#{Enum.join(vs, "|:")})"
            _ -> "#{s.name} (#{s.type}#{if s[:sensitive], do: ", sensitive", else: ""})"
          end

        label
      end)
      |> Enum.join(", ")

    accepts = Enum.map(a.protocol.accepts, &render_accept/1)
    emits = Enum.map(a.protocol.emits, fn m -> "    emits: #{render_msg(m)}" end)
    invariants = Enum.map(a.invariants, &render_invariant/1)

    bp =
      case a.backpressure do
        %{max_queue: q} -> ["    backpressure: max_queue #{q}"]
        _ -> []
      end

    externs =
      case a.externs do
        [] -> []
        list -> ["    externs: " <> Enum.map_join(list, ", ", fn e -> "#{e.module}.#{e.function}" end)]
      end

    header = "  agent #{a.name} (#{a.type})"
    state_line = if states == "", do: [], else: ["    states: #{states}"]

    ([header] ++ state_line ++ accepts ++ emits ++ invariants ++ bp ++ externs)
    |> Enum.join("\n")
  end

  defp render_accept(m) do
    base = "    accepts: #{render_msg(m)}"
    base = if m.where, do: base <> " where #{m.where}", else: base
    base = if m.max_queue, do: base <> " max_queue: #{m.max_queue}", else: base
    if m.priority, do: base <> " priority", else: base
  end

  defp render_msg(m) do
    fields =
      m.fields
      |> Enum.map(fn {name, type} -> "#{name}:#{type}" end)
      |> Enum.join(", ")

    if fields == "", do: "{:#{m.tag}}", else: "{:#{m.tag}, #{fields}}"
  end

  defp render_invariant(i) do
    within = if i[:within], do: ", #{i.within}", else: ""
    line = if i[:line], do: " line #{i.line}", else: ""
    "    #{i.kind} \"#{i.name}\" [#{i.tier}#{within}]#{line}"
  end

  defp render_system(s) do
    instances =
      Enum.map(s.agents, fn i -> "    agent #{i.instance}: #{i.type}" end)

    conns =
      case s.connections do
        [] -> []
        list -> ["    connections: " <> Enum.map_join(list, ", ", fn [f, t] -> "#{f}->#{t}" end)]
      end

    requires =
      case s.requires do
        [] -> []
        list -> ["    requires: " <> Enum.map_join(list, ", ", fn r -> r.target end)]
      end

    invariants = Enum.map(s.invariants, &render_invariant/1)
    chaos = if s.chaos, do: ["    chaos: #{s.chaos[:duration_ms]}ms"], else: []

    (["  system #{s.name}"] ++ instances ++ conns ++ requires ++ invariants ++ chaos)
    |> Enum.join("\n")
  end
end
