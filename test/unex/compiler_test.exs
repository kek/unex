defmodule Unex.CompilerTest do
  use ExUnit.Case, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "unex_compiler_#{:rand.uniform(1_000_000)}")
    {:ok, workspace} = Unex.Workspace.create(dir)
    on_exit(fn -> Unex.Workspace.destroy(workspace) end)
    %{workspace: workspace}
  end

  describe "compile/4" do
    test "compiles a Unison function to .uc bytecode", %{workspace: ws} do
      source = """
      myMain : '{IO, Exception} ()
      myMain = do printLine "compiled"
      """

      {:ok, file_path} = Unex.Workspace.write_source(ws, "compile_me.u", source)

      assert {:ok, uc_path} = Unex.Compiler.compile(ws, file_path, "myMain", "output")
      assert File.exists?(uc_path)
      assert String.ends_with?(uc_path, ".uc")
    end

    test "returns error for code that fails to typecheck", %{workspace: ws} do
      source = """
      broken : Nat
      broken = "oops"
      """

      {:ok, file_path} = Unex.Workspace.write_source(ws, "broken.u", source)

      assert {:error, _reason} = Unex.Compiler.compile(ws, file_path, "broken", "broken_out")
    end
  end
end
