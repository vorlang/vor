defmodule Vor.Relations.BidirectionalTest do
  use ExUnit.Case

  test "forward fact lookup — client bound" do
    source = """
    agent Lookup do
      relation tier(client: atom, max: integer, window: integer) do
        fact(client: :free, max: 10, window: 60000)
        fact(client: :pro, max: 100, window: 60000)
        fact(client: :enterprise, max: 1000, window: 30000)
      end

      protocol do
        accepts {:get_limit, client: atom}
        emits {:limit, max: integer, window: integer}
      end

      on {:get_limit, client: C} do
        solve tier(client: C, max: M, window: W) do
          emit {:limit, max: M, window: W}
        end
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])
    assert {:limit, %{max: 100, window: 60000}} = GenServer.call(pid, {:get_limit, %{client: :pro}})
    GenServer.stop(pid)
  end

  test "forward equation — celsius to fahrenheit" do
    source = """
    agent TempForward do
      relation temperature(celsius: integer, fahrenheit: integer) do
        fahrenheit = celsius * 9 / 5 + 32
      end

      protocol do
        accepts {:to_f, celsius: integer}
        emits {:result, fahrenheit: integer}
      end

      on {:to_f, celsius: C} do
        solve temperature(celsius: C, fahrenheit: F) do
          emit {:result, fahrenheit: F}
        end
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])
    assert {:result, %{fahrenheit: 212}} = GenServer.call(pid, {:to_f, %{celsius: 100}})
    GenServer.stop(pid)
  end

  test "inverse equation — fahrenheit to celsius" do
    source = """
    agent TempInverse do
      relation temperature(celsius: integer, fahrenheit: integer) do
        fahrenheit = celsius * 9 / 5 + 32
      end

      protocol do
        accepts {:to_c, fahrenheit: integer}
        emits {:result, celsius: integer}
      end

      on {:to_c, fahrenheit: F} do
        solve temperature(celsius: C, fahrenheit: F) do
          emit {:result, celsius: C}
        end
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])
    assert {:result, %{celsius: 100}} = GenServer.call(pid, {:to_c, %{fahrenheit: 212}})
    GenServer.stop(pid)
  end

  test "linear inversion — cost to weight" do
    source = """
    agent CostCalc do
      relation shipping(weight: integer, cost: integer) do
        cost = weight * 3 + 10
      end

      protocol do
        accepts {:weight_for_cost, cost: integer}
        emits {:result, weight: integer}
      end

      on {:weight_for_cost, cost: C} do
        solve shipping(weight: W, cost: C) do
          emit {:result, weight: W}
        end
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])
    # cost = weight * 3 + 10, so weight = (cost - 10) / 3
    # cost = 25 → weight = (25 - 10) / 3 = 5
    assert {:result, %{weight: 5}} = GenServer.call(pid, {:weight_for_cost, %{cost: 25}})
    GenServer.stop(pid)
  end
end
