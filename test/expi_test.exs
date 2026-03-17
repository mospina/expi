defmodule ExpiTest do
  use ExUnit.Case
  doctest Expi

  test "greets the world" do
    assert Expi.hello() == :world
  end
end
