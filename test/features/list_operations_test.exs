defmodule Vor.Features.ListOperationsTest do
  use ExUnit.Case

  test "list_head returns first element" do
    source = """
    agent ListHead do
      state items: list

      protocol do
        accepts {:push, value: integer}
        accepts {:peek}
        emits {:ok}
        emits {:first, value: term}
      end

      on {:push, value: V} do
        transition items: list_append(items, V)
        emit {:ok}
      end

      on {:peek} do
        first = list_head(items)
        emit {:first, value: first}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])

    assert {:first, %{value: :none}} = GenServer.call(pid, {:peek, %{}})
    GenServer.call(pid, {:push, %{value: 10}})
    GenServer.call(pid, {:push, %{value: 20}})
    assert {:first, %{value: 10}} = GenServer.call(pid, {:peek, %{}})
    GenServer.stop(pid)
  end

  test "list_tail removes first element" do
    source = """
    agent ListTail do
      state items: list

      protocol do
        accepts {:push, value: integer}
        accepts {:pop}
        accepts {:length}
        emits {:ok}
        emits {:popped}
        emits {:len, n: integer}
      end

      on {:push, value: V} do
        transition items: list_append(items, V)
        emit {:ok}
      end

      on {:pop} do
        transition items: list_tail(items)
        emit {:popped}
      end

      on {:length} do
        n = list_length(items)
        emit {:len, n: n}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])

    GenServer.call(pid, {:push, %{value: 1}})
    GenServer.call(pid, {:push, %{value: 2}})
    GenServer.call(pid, {:push, %{value: 3}})
    assert {:len, %{n: 3}} = GenServer.call(pid, {:length, %{}})

    GenServer.call(pid, {:pop, %{}})
    assert {:len, %{n: 2}} = GenServer.call(pid, {:length, %{}})

    GenServer.call(pid, {:pop, %{}})
    GenServer.call(pid, {:pop, %{}})
    GenServer.call(pid, {:pop, %{}})  # pop from empty — safe
    assert {:len, %{n: 0}} = GenServer.call(pid, {:length, %{}})
    GenServer.stop(pid)
  end

  test "list_prepend adds to front" do
    source = """
    agent ListPrepend do
      state items: list

      protocol do
        accepts {:push_front, value: integer}
        accepts {:first}
        emits {:ok}
        emits {:head, value: term}
      end

      on {:push_front, value: V} do
        transition items: list_prepend(items, V)
        emit {:ok}
      end

      on {:first} do
        h = list_head(items)
        emit {:head, value: h}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])

    GenServer.call(pid, {:push_front, %{value: 10}})
    GenServer.call(pid, {:push_front, %{value: 20}})
    GenServer.call(pid, {:push_front, %{value: 30}})
    assert {:head, %{value: 30}} = GenServer.call(pid, {:first, %{}})
    GenServer.stop(pid)
  end

  test "list_empty checks emptiness" do
    source = """
    agent ListEmpty do
      state items: list

      protocol do
        accepts {:push, value: integer}
        accepts {:check}
        emits {:ok}
        emits {:empty, result: atom}
      end

      on {:push, value: V} do
        transition items: list_append(items, V)
        emit {:ok}
      end

      on {:check} do
        result = list_empty(items)
        emit {:empty, result: result}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])

    assert {:empty, %{result: true}} = GenServer.call(pid, {:check, %{}})
    GenServer.call(pid, {:push, %{value: 1}})
    assert {:empty, %{result: false}} = GenServer.call(pid, {:check, %{}})
    GenServer.stop(pid)
  end

  test "list_head on message field variable" do
    source = """
    agent ListFromMsg do
      protocol do
        accepts {:first_of, items: list}
        emits {:result, value: term}
      end

      on {:first_of, items: I} do
        h = list_head(I)
        emit {:result, value: h}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = GenServer.start_link(result.module, [])

    assert {:result, %{value: 10}} = GenServer.call(pid, {:first_of, %{items: [10, 20, 30]}})
    assert {:result, %{value: :none}} = GenServer.call(pid, {:first_of, %{items: []}})
    GenServer.stop(pid)
  end

  test "list operations in gen_statem" do
    source = """
    agent StatemQueue do
      state phase: :accepting | :closed
      state queue: list

      protocol do
        accepts {:enqueue, item: atom}
        accepts {:dequeue}
        accepts {:close}
        emits {:ok}
        emits {:item, value: term}
        emits {:closed}
      end

      on {:enqueue, item: I} when phase == :accepting do
        transition queue: list_append(queue, I)
        emit {:ok}
      end

      on {:dequeue} when phase == :accepting do
        item = list_head(queue)
        transition queue: list_tail(queue)
        emit {:item, value: item}
      end

      on {:close} when phase == :accepting do
        transition phase: :closed
        emit {:closed}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = :gen_statem.start_link(result.module, [], [])

    :gen_statem.call(pid, {:enqueue, %{item: :a}})
    :gen_statem.call(pid, {:enqueue, %{item: :b}})
    :gen_statem.call(pid, {:enqueue, %{item: :c}})

    assert {:item, %{value: :a}} = :gen_statem.call(pid, {:dequeue, %{}})
    assert {:item, %{value: :b}} = :gen_statem.call(pid, {:dequeue, %{}})
    assert {:item, %{value: :c}} = :gen_statem.call(pid, {:dequeue, %{}})
    assert {:item, %{value: :none}} = :gen_statem.call(pid, {:dequeue, %{}})
    :gen_statem.stop(pid)
  end
end
