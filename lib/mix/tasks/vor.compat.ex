defmodule Mix.Tasks.Vor.Compat do
  use Mix.Task

  @shortdoc "Check protocol version compatibility between .vor files"

  @moduledoc """
  Compares two versions of a `.vor` file and reports whether a rolling
  deploy from old → new is safe.

  ## Usage

      mix vor.compat new.vor --against old.vor
      mix vor.compat agent.vor --against HEAD~1    # git comparison (future)

  ## Output

  Reports compatible changes (safe), incompatible changes (breaks during
  rolling deploy), and an overall COMPATIBLE/INCOMPATIBLE verdict.
  """

  def run(args) do
    Mix.Task.run("app.start")

    {opts, files, _} =
      OptionParser.parse(args, strict: [against: :string])

    case {files, opts[:against]} do
      {[new_file], old_file} when is_binary(old_file) ->
        check_against_file(new_file, old_file)

      _ ->
        Mix.shell().error("Usage: mix vor.compat <new_file.vor> --against <old_file.vor>")
    end
  end

  defp check_against_file(new_file, old_file) do
    old_source = File.read!(old_file)
    new_source = File.read!(new_file)
    compare_sources(old_source, new_source, new_file, old_file)
  end

  defp compare_sources(old_source, new_source, new_label, old_label) do
    with {:ok, old_ir} <- compile_to_ir(old_source),
         {:ok, new_ir} <- compile_to_ir(new_source) do
      old_agents = Map.new(old_ir, fn {name, ir} -> {name, ir.protocol} end)
      new_agents = Map.new(new_ir, fn {name, ir} -> {name, ir.protocol} end)

      common =
        MapSet.intersection(
          MapSet.new(Map.keys(old_agents)),
          MapSet.new(Map.keys(new_agents))
        )

      if MapSet.size(common) == 0 do
        Mix.shell().info("No common agents between #{old_label} and #{new_label}")
      else
        all_compatible =
          Enum.all?(common, fn name ->
            old_proto = protocol_to_map(old_agents[name])
            new_proto = protocol_to_map(new_agents[name])
            result = Vor.Compat.check(old_proto, new_proto)

            Mix.shell().info("\nProtocol compatibility: #{name} (#{old_label} → #{new_label})")

            if result.changes == [] do
              Mix.shell().info("  No protocol changes detected.")
              true
            else
              print_changes(result)
              result.compatible
            end
          end)

        unless all_compatible do
          Mix.raise("Protocol compatibility check failed")
        end
      end
    else
      {:error, reason} ->
        Mix.shell().error("Compilation error: #{inspect(reason)}")
        Mix.raise("Could not compile sources for comparison")
    end
  end

  defp compile_to_ir(source) do
    if String.contains?(source, "system ") do
      case Vor.Compiler.compile_system(source) do
        {:ok, result} ->
          {:ok, Map.new(result.agents, fn {name, %{ir: ir}} -> {name, ir} end)}

        {:error, _} = err ->
          err
      end
    else
      case Vor.Compiler.compile_string(source) do
        {:ok, result} ->
          {:ok, %{result.ir.name => result.ir}}

        {:error, _} = err ->
          err
      end
    end
  end

  defp protocol_to_map(nil), do: %{accepts: [], emits: []}

  defp protocol_to_map(protocol) do
    %{
      accepts: Enum.map(protocol.accepts || [], &message_type_to_map/1),
      emits: Enum.map(protocol.emits || [], &message_type_to_map/1)
    }
  end

  defp message_type_to_map(mt) do
    defaults = mt.defaults || %{}

    %{
      tag: mt.tag,
      fields:
        Enum.map(mt.fields || [], fn {name, type} ->
          %{name: name, type: type, default: Map.get(defaults, name)}
        end)
    }
  end

  defp print_changes(result) do
    compatible = Enum.filter(result.changes, & &1.compatible)
    incompatible = Enum.reject(result.changes, & &1.compatible)

    if compatible != [] do
      Mix.shell().info("\n  Compatible changes:")

      Enum.each(compatible, fn c ->
        Mix.shell().info("    #{format_change(c)}")
      end)
    end

    if incompatible != [] do
      Mix.shell().error("\n  Incompatible changes:")

      Enum.each(incompatible, fn c ->
        Mix.shell().error("    ✗ #{format_change(c)}")
      end)
    end

    if result.compatible do
      Mix.shell().info("\n  Result: COMPATIBLE — safe to rolling deploy")
    else
      Mix.shell().error("\n  Result: INCOMPATIBLE — rolling deploy will break")
    end
  end

  defp format_change(c) do
    case c.type do
      :added_accepts -> "+ accepts {:#{c.tag}} — #{c.detail}"
      :removed_accepts -> "- accepts {:#{c.tag}} — #{c.detail}"
      :added_emits -> "+ emits {:#{c.tag}} — #{c.detail}"
      :removed_emits -> "- emits {:#{c.tag}} — #{c.detail}"
      :added_field -> "~ {:#{c.tag}} added field :#{c.field} — #{c.detail}"
      :removed_field -> "~ {:#{c.tag}} removed field :#{c.field} — #{c.detail}"
      :changed_field_type -> "~ {:#{c.tag}} field :#{c.field} type changed — #{c.detail}"
    end
  end
end
