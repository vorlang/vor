defmodule Vor.Gleam.ValidatorTest do
  use ExUnit.Case

  alias Vor.Gleam.Validator

  test "validation passes when types match" do
    interface = %{
      {:"vordb@counter", :value} => %{
        params: [{:counter, :term}],
        return_type: :integer
      }
    }

    decl = %{
      module_atom: :"vordb@counter",
      function: :value,
      params: [{:counter, :term}],
      return_type: :integer
    }

    assert [] = Validator.validate([decl], interface)
  end

  test "validation passes with term opt-out" do
    interface = %{
      {:"vordb@counter", :value} => %{
        params: [{:counter, :term}],
        return_type: :integer
      }
    }

    decl = %{
      module_atom: :"vordb@counter",
      function: :value,
      params: [{:counter, :term}],
      return_type: :term
    }

    assert [] = Validator.validate([decl], interface)
  end

  test "validation warns on return type mismatch" do
    interface = %{
      {:"vordb@counter", :value} => %{
        params: [{:counter, :term}],
        return_type: :integer
      }
    }

    decl = %{
      module_atom: :"vordb@counter",
      function: :value,
      params: [{:counter, :term}],
      return_type: :binary
    }

    diagnostics = Validator.validate([decl], interface)
    assert Enum.any?(diagnostics, fn {level, _} -> level == :warning end)
  end

  test "validation errors on arity mismatch" do
    interface = %{
      {:"vordb@counter", :increment} => %{
        params: [{:counter, :term}, {:node_id, :binary}, {:amount, :integer}],
        return_type: :term
      }
    }

    decl = %{
      module_atom: :"vordb@counter",
      function: :increment,
      params: [{:counter, :term}],
      return_type: :term
    }

    diagnostics = Validator.validate([decl], interface)
    assert Enum.any?(diagnostics, fn {level, _} -> level == :error end)
  end

  test "validation errors when function not found" do
    diagnostics = Validator.validate([%{
      module_atom: :"vordb@counter",
      function: :nonexistent,
      params: [],
      return_type: :term
    }], %{})

    assert Enum.any?(diagnostics, fn {level, _} -> level == :error end)
  end
end
