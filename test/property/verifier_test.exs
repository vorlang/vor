defmodule Vor.PropertyTest.VerifierTest do
  use ExUnit.Case
  use PropCheck

  def verifier_source do
    let {s1, s2, inv_type} <- {
      elements([:idle, :active, :done, :error, :waiting]),
      elements([:running, :stopped, :ready, :closed, :finished]),
      elements([:never_emit, :never_transition, :gibberish1, :gibberish2, :gibberish3])
    } do
      inv_body = case inv_type do
        :never_emit -> "never(phase == :#{s1} and emitted({:ok, _}))"
        :never_transition -> "never(transition from: :#{s1}, to: :#{s2})"
        :gibberish1 -> "always(some_complex_property(:#{s1}))"
        :gibberish2 -> "forall X: exists Y: related(X, Y)"
        :gibberish3 -> "gibberish_that_makes_no_sense"
      end

      """
      agent VerifyTest do
        state phase: :#{s1} | :#{s2}

        protocol do
          accepts {:go}
          emits {:ok}
        end

        on {:go} when phase == :#{s1} do
          transition phase: :#{s2}
          emit {:ok}
        end

        safety "test property" proven do
          #{inv_body}
        end
      end
      """
    end
  end

  property "verifier never crashes — returns ok or error" do
    forall source <- verifier_source() do
      result = Vor.Compiler.compile_string(source)
      match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end
end
