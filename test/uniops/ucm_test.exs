defmodule Uniops.UCMTest do
  use ExUnit.Case, async: true

  describe "find/0" do
    test "returns path to ucm binary" do
      assert {:ok, path} = Uniops.UCM.find()
      assert File.exists?(path)
    end

    test "returns error when binary not found" do
      assert {:error, :not_found} = Uniops.UCM.find(name: "ucm_nonexistent_binary")
    end
  end

  describe "version/0" do
    test "returns the UCM version string" do
      assert {:ok, version} = Uniops.UCM.version()
      assert version =~ ~r/\d+\.\d+\.\d+/
    end
  end

  describe "check!/0" do
    test "returns :ok when UCM is available" do
      assert :ok = Uniops.UCM.check!()
    end
  end
end
