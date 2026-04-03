defmodule Vor.PropertyTest.ProtocolTest do
  use ExUnit.Case
  use PropCheck

  property "matching sends/accepts always pass protocol check" do
    forall {tag, field} <- {elements([:data, :msg, :event, :update]), elements([:value, :payload, :content])} do
      source = """
      agent Sender do
        protocol do
          accepts {:go}
          sends {:#{tag}, #{field}: term}
          emits {:ok}
        end

        on {:go} do
          send :receiver {:#{tag}, #{field}: :test}
          emit {:ok}
        end
      end

      agent Receiver do
        protocol do
          accepts {:#{tag}, #{field}: term}
        end

        on {:#{tag}, #{field}: V} do
          noop
        end
      end

      system TestSys do
        agent :sender, Sender()
        agent :receiver, Receiver()
        connect :sender -> :receiver
      end
      """

      case Vor.Compiler.compile_system(source) do
        {:ok, _} -> true
        other ->
          IO.puts("Expected success for matching protocols, got: #{inspect(other, limit: 50)}")
          false
      end
    end
  end

  property "mismatched tags fail protocol check" do
    forall {tag1, tag2, field} <-
        {elements([:data, :msg, :event]),
         elements([:other, :different, :wrong]),
         elements([:value, :payload])} do

      tag2_actual = if tag1 == tag2, do: :definitely_different, else: tag2

      source = """
      agent Sender do
        protocol do
          accepts {:go}
          sends {:#{tag1}, #{field}: term}
          emits {:ok}
        end

        on {:go} do
          send :receiver {:#{tag1}, #{field}: :test}
          emit {:ok}
        end
      end

      agent Receiver do
        protocol do
          accepts {:#{tag2_actual}, #{field}: term}
        end

        on {:#{tag2_actual}, #{field}: V} do
          noop
        end
      end

      system TestSys do
        agent :sender, Sender()
        agent :receiver, Receiver()
        connect :sender -> :receiver
      end
      """

      case Vor.Compiler.compile_system(source) do
        {:error, _} -> true
        _ -> false
      end
    end
  end
end
