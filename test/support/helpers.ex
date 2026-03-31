defmodule VorTest.Helpers do
  def upcase(text), do: String.upcase(text)

  def explode(_text), do: raise("boom")
end
