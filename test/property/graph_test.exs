defmodule Vor.PropertyTest.GraphTest do
  use ExUnit.Case
  use PropCheck

  def statem_source do
    all_transitions = [{:idle, :active}, {:active, :done}, {:done, :idle}, {:idle, :waiting}, {:waiting, :done}]
    let mask <- vector(length(all_transitions), boolean()) do
      transitions = all_transitions
      |> Enum.zip(mask)
      |> Enum.filter(fn {_, include} -> include end)
      |> Enum.map(fn {t, _} -> t end)
      all_states = [:idle, :active, :done, :waiting]
      valid_transitions = transitions

      handlers = valid_transitions
      |> Enum.map(fn {from, to} ->
        "  on {:go} when phase == :#{from} do\n    transition phase: :#{to}\n    emit {:ok}\n  end"
      end)

      # Add a fallback handler for idle if none exists
      handlers = if Enum.any?(valid_transitions, fn {from, _} -> from == :idle end) do
        handlers
      else
        handlers ++ ["  on {:go} when phase == :idle do\n    emit {:ok}\n  end"]
      end

      source = """
      agent GraphProp do
        state phase: :idle | :active | :done | :waiting

        protocol do
          accepts {:go}
          emits {:ok}
        end

      #{Enum.join(handlers, "\n\n")}
      end
      """

      {source, all_states, valid_transitions}
    end
  end

  property "extracted graph contains only declared states" do
    forall {source, declared_states, _} <- statem_source() do
      case Vor.Compiler.extract_graph(source) do
        {:ok, graph} ->
          Enum.all?(graph.states, fn s -> s in declared_states end)
        {:error, _} -> true
      end
    end
  end

  property "all transitions connect declared states" do
    forall {source, declared_states, _} <- statem_source() do
      case Vor.Compiler.extract_graph(source) do
        {:ok, graph} ->
          Enum.all?(graph.transitions, fn t ->
            t.from in declared_states and t.to in declared_states
          end)
        {:error, _} -> true
      end
    end
  end
end
