defmodule Vor.Codegen.ErlangTest do
  use ExUnit.Case, async: true

  alias Vor.IR

  test "echo agent IR produces valid Erlang forms" do
    ir = %IR.Agent{
      name: :Echo,
      module: Vor.Agent.Echo,
      behaviour: :gen_server,
      state_fields: [],
      protocol: %IR.Protocol{
        accepts: [%IR.MessageType{tag: :ping, fields: [payload: :term]}],
        emits: [%IR.MessageType{tag: :pong, fields: [payload: :term]}]
      },
      handlers: [
        %IR.Handler{
          pattern: %IR.MatchPattern{
            tag: :ping,
            bindings: [%IR.Binding{name: :P, field: :payload}]
          },
          guard: nil,
          actions: [
            %IR.Action{
              type: :emit,
              data: %IR.EmitAction{
                tag: :pong,
                fields: [payload: {:bound_var, :P}]
              }
            }
          ]
        }
      ],
      relations: [],
      invariants: [],
      resilience: nil
    }

    {:ok, forms} = Vor.Codegen.Erlang.generate(ir)
    assert is_list(forms)

    # The forms should compile to valid BEAM bytecode
    assert {:ok, Vor.Agent.Echo, binary, _warnings} =
      :compile.forms(forms, [:return_errors, :return_warnings])

    assert is_binary(binary)
  end
end
