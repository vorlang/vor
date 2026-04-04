defmodule Vor.Examples.ORSetNativeTest do
  use ExUnit.Case

  @version_set_source """
  agent VersionSet(node_id: atom) do
    state entries: map
    state tombstones: map
    state clock: integer

    protocol do
      accepts {:add, element: atom}
      accepts {:remove, element: atom}
      accepts {:member, element: atom}
      accepts {:merge, remote_entries: map, remote_tombstones: map}
      accepts {:get_state}
      emits {:ok}
      emits {:found}
      emits {:not_found}
      emits {:state, entries: map, tombstones: map}
    end

    on {:add, element: E} do
      new_clock = clock + 1
      transition clock: new_clock
      transition entries: map_put(entries, E, new_clock)
      emit {:ok}
    end

    on {:remove, element: E} do
      has_entry = map_has(entries, E)
      if has_entry == :true do
        entry_version = map_get(entries, E, 0)
        transition tombstones: map_put(tombstones, E, entry_version)
        emit {:ok}
      else
        emit {:ok}
      end
    end

    on {:member, element: E} do
      has_entry = map_has(entries, E)
      if has_entry == :true do
        entry_ver = map_get(entries, E, 0)
        tomb_ver = map_get(tombstones, E, 0)
        if entry_ver > tomb_ver do
          emit {:found}
        else
          emit {:not_found}
        end
      else
        emit {:not_found}
      end
    end

    on {:merge, remote_entries: RE, remote_tombstones: RT} do
      merged_entries = map_merge(entries, RE, :max)
      merged_tombstones = map_merge(tombstones, RT, :max)
      transition entries: merged_entries
      transition tombstones: merged_tombstones
      emit {:ok}
    end

    on {:get_state} do
      emit {:state, entries: entries, tombstones: tombstones}
    end
  end
  """

  test "version set: add and check membership" do
    {:ok, result} = Vor.Compiler.compile_and_load(@version_set_source)
    {:ok, pid} = GenServer.start_link(result.module, [node_id: :node1])

    GenServer.call(pid, {:add, %{element: :apple}})
    GenServer.call(pid, {:add, %{element: :banana}})
    GenServer.call(pid, {:add, %{element: :cherry}})

    assert {:found, %{}} = GenServer.call(pid, {:member, %{element: :apple}})
    assert {:found, %{}} = GenServer.call(pid, {:member, %{element: :banana}})
    assert {:not_found, %{}} = GenServer.call(pid, {:member, %{element: :grape}})

    GenServer.call(pid, {:remove, %{element: :banana}})
    assert {:not_found, %{}} = GenServer.call(pid, {:member, %{element: :banana}})
    assert {:found, %{}} = GenServer.call(pid, {:member, %{element: :apple}})
    GenServer.stop(pid)
  end

  test "version set: re-add after remove" do
    {:ok, result} = Vor.Compiler.compile_and_load(@version_set_source)
    {:ok, pid} = GenServer.start_link(result.module, [node_id: :node1])

    GenServer.call(pid, {:add, %{element: :apple}})
    assert {:found, %{}} = GenServer.call(pid, {:member, %{element: :apple}})

    GenServer.call(pid, {:remove, %{element: :apple}})
    assert {:not_found, %{}} = GenServer.call(pid, {:member, %{element: :apple}})

    GenServer.call(pid, {:add, %{element: :apple}})
    assert {:found, %{}} = GenServer.call(pid, {:member, %{element: :apple}})
    GenServer.stop(pid)
  end

  test "version set: two-node merge with convergence" do
    {:ok, result} = Vor.Compiler.compile_and_load(@version_set_source)
    {:ok, pid1} = GenServer.start_link(result.module, [node_id: :node1])
    {:ok, pid2} = GenServer.start_link(result.module, [node_id: :node2])

    GenServer.call(pid1, {:add, %{element: :apple}})
    GenServer.call(pid1, {:add, %{element: :banana}})
    GenServer.call(pid2, {:add, %{element: :cherry}})

    {:state, %{entries: e1, tombstones: t1}} = GenServer.call(pid1, {:get_state, %{}})
    {:state, %{entries: e2, tombstones: t2}} = GenServer.call(pid2, {:get_state, %{}})

    GenServer.call(pid1, {:merge, %{remote_entries: e2, remote_tombstones: t2}})
    GenServer.call(pid2, {:merge, %{remote_entries: e1, remote_tombstones: t1}})

    for pid <- [pid1, pid2] do
      assert {:found, %{}} = GenServer.call(pid, {:member, %{element: :apple}})
      assert {:found, %{}} = GenServer.call(pid, {:member, %{element: :banana}})
      assert {:found, %{}} = GenServer.call(pid, {:member, %{element: :cherry}})
    end

    GenServer.stop(pid1)
    GenServer.stop(pid2)
  end

  test "version set: merge is commutative" do
    {:ok, result} = Vor.Compiler.compile_and_load(@version_set_source)

    {:ok, a} = GenServer.start_link(result.module, [node_id: :a])
    {:ok, b} = GenServer.start_link(result.module, [node_id: :b])
    {:ok, c} = GenServer.start_link(result.module, [node_id: :c])

    GenServer.call(a, {:add, %{element: :x}})
    GenServer.call(a, {:add, %{element: :y}})
    GenServer.call(b, {:add, %{element: :y}})
    GenServer.call(b, {:add, %{element: :z}})
    GenServer.call(b, {:remove, %{element: :z}})
    GenServer.call(c, {:add, %{element: :x}})
    GenServer.call(c, {:add, %{element: :w}})

    {:state, %{entries: ea, tombstones: ta}} = GenServer.call(a, {:get_state, %{}})
    {:state, %{entries: eb, tombstones: tb}} = GenServer.call(b, {:get_state, %{}})
    {:state, %{entries: ec, tombstones: tc}} = GenServer.call(c, {:get_state, %{}})

    {:ok, r1} = GenServer.start_link(result.module, [node_id: :r1])
    GenServer.call(r1, {:merge, %{remote_entries: ea, remote_tombstones: ta}})
    GenServer.call(r1, {:merge, %{remote_entries: eb, remote_tombstones: tb}})
    GenServer.call(r1, {:merge, %{remote_entries: ec, remote_tombstones: tc}})

    {:ok, r2} = GenServer.start_link(result.module, [node_id: :r2])
    GenServer.call(r2, {:merge, %{remote_entries: ec, remote_tombstones: tc}})
    GenServer.call(r2, {:merge, %{remote_entries: ea, remote_tombstones: ta}})
    GenServer.call(r2, {:merge, %{remote_entries: eb, remote_tombstones: tb}})

    for elem <- [:x, :y, :z, :w] do
      r1_result = GenServer.call(r1, {:member, %{element: elem}})
      r2_result = GenServer.call(r2, {:member, %{element: elem}})
      assert r1_result == r2_result, "Disagreement on #{elem}"
    end

    assert {:found, %{}} = GenServer.call(r1, {:member, %{element: :x}})
    assert {:found, %{}} = GenServer.call(r1, {:member, %{element: :y}})
    assert {:not_found, %{}} = GenServer.call(r1, {:member, %{element: :z}})
    assert {:found, %{}} = GenServer.call(r1, {:member, %{element: :w}})

    Enum.each([a, b, c, r1, r2], &GenServer.stop/1)
  end

  test "version set: merge is idempotent" do
    {:ok, result} = Vor.Compiler.compile_and_load(@version_set_source)

    {:ok, a} = GenServer.start_link(result.module, [node_id: :a])
    {:ok, b} = GenServer.start_link(result.module, [node_id: :b])

    GenServer.call(a, {:add, %{element: :x}})
    GenServer.call(a, {:add, %{element: :y}})
    GenServer.call(a, {:remove, %{element: :y}})
    GenServer.call(b, {:add, %{element: :z}})

    {:state, %{entries: eb, tombstones: tb}} = GenServer.call(b, {:get_state, %{}})

    GenServer.call(a, {:merge, %{remote_entries: eb, remote_tombstones: tb}})
    {:state, %{entries: e1, tombstones: t1}} = GenServer.call(a, {:get_state, %{}})
    GenServer.call(a, {:merge, %{remote_entries: eb, remote_tombstones: tb}})
    {:state, %{entries: e2, tombstones: t2}} = GenServer.call(a, {:get_state, %{}})

    assert e1 == e2
    assert t1 == t2

    GenServer.stop(a)
    GenServer.stop(b)
  end
end
