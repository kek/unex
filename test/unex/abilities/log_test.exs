defmodule Unex.Abilities.LogTest do
  use ExUnit.Case, async: false

  alias Unex.Abilities.Log

  setup do
    log = start_supervised!({Log, name: :test_log, max_entries: 5})
    %{log: log}
  end

  describe "append/3 and recent/2" do
    test "stores and retrieves log entries", %{log: log} do
      Log.append(log, :info, "hello", %{service: "greeter"})
      entries = Log.recent(log, 10)
      assert length(entries) == 1
      assert hd(entries).message == "hello"
      assert hd(entries).level == :info
      assert hd(entries).metadata == %{service: "greeter"}
    end

    test "returns entries in reverse chronological order", %{log: log} do
      Log.append(log, :info, "first", %{})
      Log.append(log, :info, "second", %{})
      Log.append(log, :info, "third", %{})
      entries = Log.recent(log, 10)
      messages = Enum.map(entries, & &1.message)
      assert messages == ["third", "second", "first"]
    end

    test "ring buffer evicts oldest when full", %{log: log} do
      for i <- 1..7 do
        Log.append(log, :info, "msg-#{i}", %{})
      end

      entries = Log.recent(log, 10)
      assert length(entries) == 5
      messages = Enum.map(entries, & &1.message)
      assert "msg-7" in messages
      assert "msg-6" in messages
      refute "msg-1" in messages
    end
  end

  describe "convenience functions" do
    test "info/error/warn append with correct level", %{log: log} do
      Log.info(log, "info msg")
      Log.error(log, "error msg")
      Log.warn(log, "warn msg")

      entries = Log.recent(log, 10)
      levels = Enum.map(entries, & &1.level)
      assert :info in levels
      assert :error in levels
      assert :warn in levels
    end
  end
end
