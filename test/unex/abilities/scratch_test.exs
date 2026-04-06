defmodule Unex.Abilities.ScratchTest do
  use ExUnit.Case, async: false

  alias Unex.Abilities.Scratch

  setup do
    cache = start_supervised!({Scratch, name: :test_scratch})
    %{cache: cache}
  end

  describe "put/3 and get/2" do
    test "stores and retrieves a value", %{cache: c} do
      assert :ok = Scratch.put(c, "session:abc", "user-data")
      assert {:ok, "user-data"} = Scratch.get(c, "session:abc")
    end

    test "returns :not_found for missing key", %{cache: c} do
      assert :not_found = Scratch.get(c, "nope")
    end

    test "overwrites existing key", %{cache: c} do
      Scratch.put(c, "k", "v1")
      Scratch.put(c, "k", "v2")
      assert {:ok, "v2"} = Scratch.get(c, "k")
    end
  end

  describe "delete/2" do
    test "removes a key", %{cache: c} do
      Scratch.put(c, "temp", "val")
      assert :ok = Scratch.delete(c, "temp")
      assert :not_found = Scratch.get(c, "temp")
    end
  end

  describe "list/1" do
    test "returns all keys", %{cache: c} do
      Scratch.put(c, "a", "1")
      Scratch.put(c, "b", "2")
      keys = Scratch.list(c)
      assert "a" in keys
      assert "b" in keys
    end
  end
end
