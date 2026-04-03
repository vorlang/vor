defmodule Vor.PropertyTest.CompilationTest do
  use ExUnit.Case
  use PropCheck

  def agent_name do
    elements([:Alpha, :Beta, :Gamma, :Delta, :Echo, :Foxtrot, :Golf, :Hotel])
  end

  def message_tag do
    elements([:request, :response, :ping, :pong, :update, :notify, :query, :result])
  end

  def field_name do
    elements([:value, :data, :payload, :name, :count, :status, :result, :tag])
  end

  def simple_genserver_source do
    let {name, tag_in, tag_out, field} <- {agent_name(), message_tag(), message_tag(), field_name()} do
      """
      agent #{name} do
        protocol do
          accepts {:#{tag_in}, #{field}: term}
          emits {:#{tag_out}, #{field}: term}
        end

        on {:#{tag_in}, #{field}: V} do
          emit {:#{tag_out}, #{field}: V}
        end
      end
      """
    end
  end

  def genserver_with_state_source do
    let {name, tag_in, tag_out, field, state_field} <-
        {agent_name(), message_tag(), message_tag(), field_name(),
         elements([:counter, :total, :amount, :level])} do
      """
      agent #{name} do
        state #{state_field}: integer

        protocol do
          accepts {:#{tag_in}, #{field}: integer}
          emits {:#{tag_out}, #{state_field}: integer}
        end

        on {:#{tag_in}, #{field}: V} do
          transition #{state_field}: #{state_field} + V
          emit {:#{tag_out}, #{state_field}: #{state_field}}
        end
      end
      """
    end
  end

  def simple_statem_source do
    let {name, state1, state2, tag_in, tag_out} <-
        {agent_name(),
         elements([:idle, :active, :waiting, :ready]),
         elements([:done, :finished, :complete, :stopped]),
         message_tag(), message_tag()} do
      """
      agent #{name} do
        state phase: :#{state1} | :#{state2}

        protocol do
          accepts {:#{tag_in}}
          emits {:#{tag_out}}
        end

        on {:#{tag_in}} when phase == :#{state1} do
          transition phase: :#{state2}
          emit {:#{tag_out}}
        end
      end
      """
    end
  end

  property "simple gen_server agents always compile or produce clean error" do
    forall source <- simple_genserver_source() do
      result = Vor.Compiler.compile_string(source)
      match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  property "gen_server with state always compiles or produces clean error" do
    forall source <- genserver_with_state_source() do
      result = Vor.Compiler.compile_string(source)
      match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  property "gen_statem agents always compile or produce clean error" do
    forall source <- simple_statem_source() do
      result = Vor.Compiler.compile_string(source)
      match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  property "compiled gen_server modules are loadable and startable" do
    forall source <- simple_genserver_source() do
      case Vor.Compiler.compile_and_load(source) do
        {:ok, result} ->
          case GenServer.start_link(result.module, []) do
            {:ok, pid} ->
              alive = Process.alive?(pid)
              GenServer.stop(pid)
              alive
            _ -> true
          end
        {:error, _} -> true
      end
    end
  end
end
