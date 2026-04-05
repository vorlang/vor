defmodule Vor.Gleam.Validator do
  @moduledoc """
  Validates Vor extern declarations against Gleam package-interface.json.
  Optional — skipped gracefully if no interface file exists.
  """

  def validate(extern_decls, interface) do
    Enum.flat_map(extern_decls, fn decl ->
      key = {decl.module_atom, decl.function}
      case Map.get(interface, key) do
        nil ->
          [{:error, "Function #{inspect(key)} not found in Gleam interface"}]

        gleam_fn ->
          check_arity(decl, gleam_fn) ++
          check_param_types(decl, gleam_fn) ++
          check_return_type(decl, gleam_fn)
      end
    end)
  end

  defp check_arity(decl, gleam_fn) do
    vor_arity = length(decl.params)
    gleam_arity = length(gleam_fn.params)
    if vor_arity != gleam_arity do
      [{:error, "Arity mismatch for #{decl.function}: Vor declares #{vor_arity}, Gleam has #{gleam_arity}"}]
    else
      []
    end
  end

  defp check_param_types(decl, gleam_fn) do
    Enum.zip(decl.params, gleam_fn.params)
    |> Enum.with_index()
    |> Enum.flat_map(fn {{{_vor_name, vor_type}, {_gleam_name, gleam_type}}, idx} ->
      if compatible?(vor_type, gleam_type) do
        []
      else
        [{:warning, "Parameter #{idx + 1} of #{decl.function}: Vor declares #{vor_type}, Gleam expects #{gleam_type}"}]
      end
    end)
  end

  defp check_return_type(decl, gleam_fn) do
    if compatible?(decl.return_type, gleam_fn.return_type) do
      []
    else
      [{:warning, "Return type of #{decl.function}: Vor declares #{decl.return_type}, Gleam returns #{gleam_fn.return_type}"}]
    end
  end

  defp compatible?(:term, _), do: true
  defp compatible?(_, :term), do: true
  defp compatible?(a, a), do: true
  defp compatible?(_, _), do: false
end
