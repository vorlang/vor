defmodule Vor.Gleam.Interface do
  @moduledoc """
  Reads and parses Gleam package-interface.json for type validation.
  """

  def load(path) do
    with {:ok, json} <- File.read(path),
         {:ok, data} <- Jason.decode(json) do
      {:ok, parse_interface(data)}
    end
  end

  defp parse_interface(data) do
    modules = data["modules"] || %{}

    for {module_name, module_data} <- modules,
        {fn_name, fn_data} <- module_data["functions"] || %{},
        into: %{} do
      key = {normalize_module(module_name), String.to_atom(fn_name)}
      value = %{
        params: parse_params(fn_data["parameters"] || []),
        return_type: parse_type(fn_data["return"])
      }
      {key, value}
    end
  end

  defp normalize_module(name) do
    name |> String.replace("/", "@") |> String.to_atom()
  end

  defp parse_params(params) do
    Enum.map(params, fn p ->
      {String.to_atom(p["name"]), parse_type(p["type"])}
    end)
  end

  defp parse_type(%{"name" => "Int"}), do: :integer
  defp parse_type(%{"name" => "String"}), do: :binary
  defp parse_type(%{"name" => "Bool"}), do: :atom
  defp parse_type(%{"name" => "List", "parameters" => _}), do: :list
  defp parse_type(%{"name" => "Dict", "parameters" => _}), do: :map
  defp parse_type(%{"name" => "Nil"}), do: :atom
  defp parse_type(%{"name" => "Result", "parameters" => _}), do: :result
  defp parse_type(_), do: :term
end
