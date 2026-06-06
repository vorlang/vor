defmodule Vor.Features.CompatTest do
  use ExUnit.Case

  # ----------------------------------------------------------------------
  # Vor.Compat core algorithm
  # ----------------------------------------------------------------------

  test "adding a new accepts tag is compatible" do
    old = %{accepts: [%{tag: :order, fields: [%{name: :customer, type: :atom, default: nil}]}], emits: []}
    new = %{accepts: [
      %{tag: :order, fields: [%{name: :customer, type: :atom, default: nil}]},
      %{tag: :bulk, fields: [%{name: :items, type: :list, default: nil}]}
    ], emits: []}

    result = Vor.Compat.check(old, new)
    assert result.compatible
    assert Enum.any?(result.changes, &(&1.type == :added_accepts))
  end

  test "removing an accepts tag is incompatible" do
    old = %{accepts: [
      %{tag: :order, fields: [%{name: :customer, type: :atom, default: nil}]},
      %{tag: :cancel, fields: [%{name: :id, type: :atom, default: nil}]}
    ], emits: []}
    new = %{accepts: [%{tag: :order, fields: [%{name: :customer, type: :atom, default: nil}]}], emits: []}

    result = Vor.Compat.check(old, new)
    refute result.compatible
    assert Enum.any?(result.changes, &(&1.type == :removed_accepts))
  end

  test "adding a field without default is incompatible" do
    old = %{accepts: [%{tag: :order, fields: [%{name: :customer, type: :atom, default: nil}]}], emits: []}
    new = %{accepts: [%{tag: :order, fields: [
      %{name: :customer, type: :atom, default: nil},
      %{name: :quantity, type: :integer, default: nil}
    ]}], emits: []}

    result = Vor.Compat.check(old, new)
    refute result.compatible
  end

  test "adding a field with default is compatible" do
    old = %{accepts: [%{tag: :order, fields: [%{name: :customer, type: :atom, default: nil}]}], emits: []}
    new = %{accepts: [%{tag: :order, fields: [
      %{name: :customer, type: :atom, default: nil},
      %{name: :quantity, type: :integer, default: 1}
    ]}], emits: []}

    result = Vor.Compat.check(old, new)
    assert result.compatible
  end

  test "adding a new emits tag is compatible" do
    old = %{accepts: [], emits: [%{tag: :ok, fields: []}]}
    new = %{accepts: [], emits: [%{tag: :ok, fields: []}, %{tag: :detailed, fields: [%{name: :info, type: :binary, default: nil}]}]}

    result = Vor.Compat.check(old, new)
    assert result.compatible
  end

  test "removing an emits tag is incompatible" do
    old = %{accepts: [], emits: [%{tag: :ok, fields: []}, %{tag: :error, fields: [%{name: :reason, type: :atom, default: nil}]}]}
    new = %{accepts: [], emits: [%{tag: :ok, fields: []}]}

    result = Vor.Compat.check(old, new)
    refute result.compatible
  end

  test "removing a field from emits is incompatible" do
    old = %{accepts: [], emits: [%{tag: :ok, fields: [%{name: :id, type: :atom, default: nil}, %{name: :ts, type: :integer, default: nil}]}]}
    new = %{accepts: [], emits: [%{tag: :ok, fields: [%{name: :id, type: :atom, default: nil}]}]}

    result = Vor.Compat.check(old, new)
    refute result.compatible
  end

  test "widening a field type is compatible" do
    old = %{accepts: [%{tag: :order, fields: [%{name: :value, type: :integer, default: nil}]}], emits: []}
    new = %{accepts: [%{tag: :order, fields: [%{name: :value, type: :term, default: nil}]}], emits: []}

    result = Vor.Compat.check(old, new)
    assert result.compatible
  end

  test "narrowing a field type is incompatible" do
    old = %{accepts: [%{tag: :order, fields: [%{name: :value, type: :term, default: nil}]}], emits: []}
    new = %{accepts: [%{tag: :order, fields: [%{name: :value, type: :integer, default: nil}]}], emits: []}

    result = Vor.Compat.check(old, new)
    refute result.compatible
  end

  test "no changes is compatible with empty changes list" do
    proto = %{accepts: [%{tag: :order, fields: [%{name: :customer, type: :atom, default: nil}]}],
              emits: [%{tag: :ok, fields: []}]}

    result = Vor.Compat.check(proto, proto)
    assert result.compatible
    assert result.changes == []
  end

  test "removing a field from accepts is compatible (receiver ignores extra)" do
    old = %{accepts: [%{tag: :order, fields: [
      %{name: :customer, type: :atom, default: nil},
      %{name: :legacy, type: :atom, default: nil}
    ]}], emits: []}
    new = %{accepts: [%{tag: :order, fields: [%{name: :customer, type: :atom, default: nil}]}], emits: []}

    result = Vor.Compat.check(old, new)
    assert result.compatible
  end

  # ----------------------------------------------------------------------
  # Mix task smoke test (file comparison)
  # ----------------------------------------------------------------------

  test "mix vor.compat compares two .vor files" do
    old_source = """
    agent Worker do
      protocol do
        accepts {:task, name: atom}
        emits {:ok}
      end
      on {:task, name: N} do
        emit {:ok}
      end
    end
    """

    new_source = """
    agent Worker do
      protocol do
        accepts {:task, name: atom}
        accepts {:bulk, items: list}
        emits {:ok}
      end
      on {:task, name: N} do
        emit {:ok}
      end
      on {:bulk, items: I} do
        emit {:ok}
      end
    end
    """

    old_path = Path.join(System.tmp_dir!(), "vor_compat_old_#{:rand.uniform(100000)}.vor")
    new_path = Path.join(System.tmp_dir!(), "vor_compat_new_#{:rand.uniform(100000)}.vor")
    File.write!(old_path, old_source)
    File.write!(new_path, new_source)

    # The mix task should not raise (compatible change)
    Mix.Tasks.Vor.Compat.run([new_path, "--against", old_path])

    File.rm(old_path)
    File.rm(new_path)
  end
end
