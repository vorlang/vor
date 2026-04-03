defmodule Vor.TestHelpers.InitHelper do
  def load_value, do: 99
  def crash, do: raise("init crash")
end
