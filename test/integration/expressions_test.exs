defmodule Vor.Integration.ExpressionsTest do
  use ExUnit.Case

  test "multiple state fields with data map" do
    source = """
    agent MultiState do
      state phase: :idle | :active
      state counter: integer
      state label: atom

      protocol do
        accepts {:go, id: term}
        emits {:ok, count: integer}
      end

      on {:go, id: I} when phase == :idle do
        transition phase: :active
        transition counter: counter + 1
        transition label: :started
        emit {:ok, count: counter + 1}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = :gen_statem.start_link(result.module, [], [])
    result = :gen_statem.call(pid, {:go, %{id: 1}})
    assert {:ok, %{count: 1}} = result
    :gen_statem.stop(pid)
  end

  test "data fields have default values" do
    source = """
    agent Defaults do
      state phase: :a | :b
      state count: integer
      state name: atom

      protocol do
        accepts {:check, id: term}
        emits {:status, count: integer, name: atom}
      end

      on {:check, id: I} when phase == :a do
        emit {:status, count: count, name: name}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = :gen_statem.start_link(result.module, [], [])
    result = :gen_statem.call(pid, {:check, %{id: 1}})
    assert {:status, %{count: 0, name: nil}} = result
    :gen_statem.stop(pid)
  end

  test "standalone variable binding from arithmetic" do
    source = """
    agent ArithBinding do
      state phase: :idle | :done

      protocol do
        accepts {:compute, value: integer}
        emits {:result, doubled: integer}
      end

      on {:compute, value: V} when phase == :idle do
        doubled = V + V
        transition phase: :done
        emit {:result, doubled: doubled}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = :gen_statem.start_link(result.module, [], [])
    result = :gen_statem.call(pid, {:compute, %{value: 5}})
    assert {:result, %{doubled: 10}} = result
    :gen_statem.stop(pid)
  end

  test "nested if/else" do
    source = """
    agent NestedIf do
      state phase: :idle | :done

      protocol do
        accepts {:classify, a: integer, b: integer}
        emits {:result, class: atom}
      end

      on {:classify, a: A, b: B} when phase == :idle do
        if A > B do
          if A > 100 do
            emit {:result, class: :a_large}
          else
            emit {:result, class: :a_bigger}
          end
        else
          emit {:result, class: :b_bigger}
        end
        transition phase: :done
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = :gen_statem.start_link(result.module, [], [])
    r = :gen_statem.call(pid, {:classify, %{a: 200, b: 50}})
    assert {:result, %{class: :a_large}} = r
    :gen_statem.stop(pid)
  end

  test "boolean logic in if conditions" do
    source = """
    agent BoolIf do
      state phase: :idle | :done

      protocol do
        accepts {:check, x: integer, y: integer}
        emits {:result, ok: atom}
      end

      on {:check, x: X, y: Y} when phase == :idle do
        if X > 0 and Y > 0 do
          emit {:result, ok: :both_positive}
        else
          emit {:result, ok: :not_both}
        end
        transition phase: :done
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = :gen_statem.start_link(result.module, [], [])
    r = :gen_statem.call(pid, {:check, %{x: 5, y: 3}})
    assert {:result, %{ok: :both_positive}} = r
    :gen_statem.stop(pid)
  end

  test "int-first arithmetic" do
    source = """
    agent IntFirst do
      state phase: :idle | :done

      protocol do
        accepts {:calc, value: integer}
        emits {:result, answer: integer}
      end

      on {:calc, value: V} when phase == :idle do
        result = 10 - V
        emit {:result, answer: result}
        transition phase: :done
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = :gen_statem.start_link(result.module, [], [])
    r = :gen_statem.call(pid, {:calc, %{value: 3}})
    assert {:result, %{answer: 7}} = r
    :gen_statem.stop(pid)
  end

  test "transition with arithmetic" do
    source = """
    agent TransArith do
      state phase: :counting | :done
      state count: integer

      protocol do
        accepts {:increment, id: term}
        accepts {:finish, id: term}
        emits {:total, count: integer}
      end

      on {:increment, id: I} when phase == :counting do
        transition count: count + 1
      end

      on {:finish, id: I} when phase == :counting do
        transition phase: :done
        emit {:total, count: count}
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = :gen_statem.start_link(result.module, [], [])
    :gen_statem.cast(pid, {:increment, %{id: 1}})
    :gen_statem.cast(pid, {:increment, %{id: 2}})
    :gen_statem.cast(pid, {:increment, %{id: 3}})
    Process.sleep(50)
    r = :gen_statem.call(pid, {:finish, %{id: 4}})
    assert {:total, %{count: 3}} = r
    :gen_statem.stop(pid)
  end

  test "raft-like vote handling" do
    source = """
    agent VoteHandler(cluster_size: integer) do
      state role: :follower | :candidate | :leader
      state current_term: integer
      state vote_count: integer

      protocol do
        accepts {:start_election, id: term}
        accepts {:vote_granted, term: integer}
        accepts {:request_vote, term: integer, candidate: atom}
        emits {:became_leader, term: integer}
        emits {:vote_response, granted: atom}
        emits {:election_started, term: integer}
      end

      on {:start_election, id: I} when role == :follower do
        transition role: :candidate
        transition current_term: current_term + 1
        transition vote_count: 1
        emit {:election_started, term: current_term + 1}
      end

      on {:vote_granted, term: T} when role == :candidate do
        transition vote_count: vote_count + 1
      end

      on {:request_vote, term: T, candidate: C} when role == :follower do
        transition current_term: T
        emit {:vote_response, granted: :true}
      end

      safety "no leader emits election_started" proven do
        never(role == :leader and emitted({:election_started, _}))
      end
    end
    """

    {:ok, result} = Vor.Compiler.compile_and_load(source)
    {:ok, pid} = :gen_statem.start_link(result.module, [cluster_size: 3], [])

    r = :gen_statem.call(pid, {:start_election, %{id: 1}})
    assert {:election_started, %{term: 1}} = r

    {state, data} = :sys.get_state(pid)
    assert state == :candidate
    assert data.vote_count == 1 or Map.get(data, :vote_count) == 1
    :gen_statem.stop(pid)
  end
end
