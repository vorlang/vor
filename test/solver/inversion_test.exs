defmodule Vor.Solver.InversionTest do
  use ExUnit.Case, async: true

  alias Vor.Solver

  test "invert addition: F = C + 32 → C = F - 32" do
    eq = {:assign, :fahrenheit, {:add, {:ref, :celsius}, 32}}
    {:ok, {:assign, :celsius, inverted}} = Solver.invert(eq, :celsius)
    # F - 32
    assert Solver.eval(inverted, %{fahrenheit: 212}) == 180
  end

  test "invert multiplication: F = C * 9 → C = F / 9" do
    eq = {:assign, :fahrenheit, {:mul, {:ref, :celsius}, 9}}
    {:ok, {:assign, :celsius, inverted}} = Solver.invert(eq, :celsius)
    assert Solver.eval(inverted, %{fahrenheit: 900}) == 100
  end

  test "invert compound: F = C * 9 / 5 + 32 → C = (F - 32) * 5 / 9" do
    eq = {:assign, :fahrenheit, {:add, {:div, {:mul, {:ref, :celsius}, 9}, 5}, 32}}
    {:ok, {:assign, :celsius, inverted}} = Solver.invert(eq, :celsius)
    assert Solver.eval(inverted, %{fahrenheit: 212}) == 100
    assert Solver.eval(inverted, %{fahrenheit: 32}) == 0
  end

  test "forward: target is already lhs" do
    eq = {:assign, :fahrenheit, {:add, {:ref, :celsius}, 32}}
    {:ok, {:assign, :fahrenheit, forward}} = Solver.invert(eq, :fahrenheit)
    assert Solver.eval(forward, %{celsius: 100}) == 132
  end

  test "invert cost = weight * 3 + 10 → weight = (cost - 10) / 3" do
    eq = {:assign, :cost, {:add, {:mul, {:ref, :weight}, 3}, 10}}
    {:ok, {:assign, :weight, inverted}} = Solver.invert(eq, :weight)
    assert Solver.eval(inverted, %{cost: 25}) == 5
    assert Solver.eval(inverted, %{cost: 10}) == 0
  end

  test "invert division: Y = 100 / X → X = 100 / Y" do
    eq = {:assign, :y, {:div, 100, {:ref, :x}}}
    {:ok, {:assign, :x, inverted}} = Solver.invert(eq, :x)
    assert Solver.eval(inverted, %{y: 10}) == 10
    assert Solver.eval(inverted, %{y: 25}) == 4
  end

  test "invert subtraction: Y = 100 - X → X = 100 - Y" do
    eq = {:assign, :y, {:sub, 100, {:ref, :x}}}
    {:ok, {:assign, :x, inverted}} = Solver.invert(eq, :x)
    assert Solver.eval(inverted, %{y: 90}) == 10
  end

  test "fails for quadratic" do
    eq = {:assign, :y, {:mul, {:ref, :x}, {:ref, :x}}}
    assert {:error, :non_linear} = Solver.invert(eq, :x)
  end

  test "fails for variable not in equation" do
    eq = {:assign, :y, {:add, {:ref, :x}, 1}}
    assert {:error, :variable_not_in_equation} = Solver.invert(eq, :z)
  end
end
