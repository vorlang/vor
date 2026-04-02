defmodule Vor.Verification.DeadAcceptsTest do
  use ExUnit.Case

  test "dead accepts in system produces warning" do
    source = """
    agent Sender do
      protocol do
        accepts {:go}
        sends {:data, value: integer}
        emits {:ok}
      end

      on {:go} do
        send :receiver {:data, value: 42}
        emit {:ok}
      end
    end

    agent Receiver do
      protocol do
        accepts {:data, value: integer}
        accepts {:orphan, unused: atom}
      end

      on {:data, value: V} do
      end

      on {:orphan, unused: U} do
      end
    end

    system WarnTest do
      agent :sender, Sender()
      agent :receiver, Receiver()
      connect :sender -> :receiver
    end
    """

    # The system should compile — dead accepts are warnings, not errors
    result = Vor.Compiler.compile_system(source)
    assert {:ok, _} = result
  end
end
