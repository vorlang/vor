defmodule Vor.TestHelpers.MaybeCrash do
  def run(:yes), do: raise("intentional crash")
  def run(:no), do: :ok
  def run(_), do: :ok
end
