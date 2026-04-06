defmodule Unex.WorkspaceTest do
  use ExUnit.Case, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "unex_test_#{:rand.uniform(1_000_000)}")
    on_cleanup = fn -> File.rm_rf!(dir) end

    on_exit(on_cleanup)
    %{dir: dir}
  end

  describe "create/1" do
    test "creates a workspace directory with a Unison codebase", %{dir: dir} do
      assert {:ok, workspace} = Unex.Workspace.create(dir)
      assert workspace.path == dir
      assert File.dir?(dir)
    end
  end

  describe "write_source/3" do
    test "writes a .u file into the workspace", %{dir: dir} do
      {:ok, workspace} = Unex.Workspace.create(dir)
      source = """
      myMain : '{IO, Exception} ()
      myMain = do printLine "hello"
      """

      assert {:ok, file_path} = Unex.Workspace.write_source(workspace, "scratch.u", source)
      assert File.exists?(file_path)
      assert File.read!(file_path) == source
    end
  end

  describe "destroy/1" do
    test "removes the workspace directory", %{dir: dir} do
      {:ok, workspace} = Unex.Workspace.create(dir)
      assert :ok = Unex.Workspace.destroy(workspace)
      refute File.dir?(dir)
    end
  end
end
