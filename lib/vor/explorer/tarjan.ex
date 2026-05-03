defmodule Vor.Explorer.Tarjan do
  @moduledoc """
  Tarjan's algorithm for finding strongly connected components in a
  directed graph. Runs in O(V + E).

  Used by the liveness checker to find cycles in the product state graph.
  A non-trivial SCC (size > 1 or self-loop) represents a cycle — a set of
  states the system can loop through forever.
  """

  @doc """
  Find all non-trivial SCCs in the graph.

  `graph` is `%{node => [successor_nodes]}`. Returns a list of SCCs,
  each SCC being a list of nodes. Only returns SCCs with actual cycles
  (size > 1 or self-loops).
  """
  def find_sccs(graph) when is_map(graph) do
    state = %{
      index: 0,
      stack: [],
      on_stack: MapSet.new(),
      indices: %{},
      lowlinks: %{},
      sccs: []
    }

    final =
      graph
      |> Map.keys()
      |> Enum.reduce(state, fn node, acc ->
        if Map.has_key?(acc.indices, node),
          do: acc,
          else: strongconnect(node, graph, acc)
      end)

    final.sccs
    |> Enum.filter(fn scc ->
      length(scc) > 1 or has_self_loop?(hd(scc), graph)
    end)
  end

  defp strongconnect(v, graph, state) do
    state = %{
      state
      | indices: Map.put(state.indices, v, state.index),
        lowlinks: Map.put(state.lowlinks, v, state.index),
        index: state.index + 1,
        stack: [v | state.stack],
        on_stack: MapSet.put(state.on_stack, v)
    }

    successors = Map.get(graph, v, [])

    state =
      Enum.reduce(successors, state, fn w, acc ->
        cond do
          not Map.has_key?(acc.indices, w) ->
            acc = strongconnect(w, graph, acc)

            %{
              acc
              | lowlinks:
                  Map.update!(acc.lowlinks, v, fn lv ->
                    min(lv, acc.lowlinks[w])
                  end)
            }

          MapSet.member?(acc.on_stack, w) ->
            %{
              acc
              | lowlinks:
                  Map.update!(acc.lowlinks, v, fn lv ->
                    min(lv, acc.indices[w])
                  end)
            }

          true ->
            acc
        end
      end)

    if state.lowlinks[v] == state.indices[v] do
      {scc, rest_stack, new_on_stack} = pop_scc(v, state.stack, state.on_stack)

      %{
        state
        | stack: rest_stack,
          on_stack: new_on_stack,
          sccs: [scc | state.sccs]
      }
    else
      state
    end
  end

  defp pop_scc(v, stack, on_stack, acc \\ []) do
    [w | rest] = stack
    on_stack = MapSet.delete(on_stack, w)
    acc = [w | acc]

    if w == v do
      {acc, rest, on_stack}
    else
      pop_scc(v, rest, on_stack, acc)
    end
  end

  defp has_self_loop?(node, graph) do
    node in Map.get(graph, node, [])
  end
end
