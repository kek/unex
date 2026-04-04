defmodule Uniops.CompilerTest do
  use ExUnit.Case, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "uniops_compiler_#{:rand.uniform(1_000_000)}")
    {:ok, workspace} = Uniops.Workspace.create(dir)
    on_exit(fn -> Uniops.Workspace.destroy(workspace) end)
    %{workspace: workspace}
  end

  describe "compile/4" do
    test "compiles a Unison function to .uc bytecode", %{workspace: ws} do
      source = """
      myMain : '{IO, Exception} ()
      myMain = do printLine "compiled"
      """

      {:ok, file_path} = Uniops.Workspace.write_source(ws, "compile_me.u", source)

      assert {:ok, uc_path} = Uniops.Compiler.compile(ws, file_path, "myMain", "output")
      assert File.exists?(uc_path)
      assert String.ends_with?(uc_path, ".uc")
    end

    test "returns error for code that fails to typecheck", %{workspace: ws} do
      source = """
      broken : Nat
      broken = "oops"
      """

      {:ok, file_path} = Uniops.Workspace.write_source(ws, "broken.u", source)

      assert {:error, _reason} = Uniops.Compiler.compile(ws, file_path, "broken", "broken_out")
    end
  end
end
