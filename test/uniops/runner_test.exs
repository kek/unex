defmodule Uniops.RunnerTest do
  use ExUnit.Case, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "uniops_runner_#{:rand.uniform(1_000_000)}")
    {:ok, workspace} = Uniops.Workspace.create(dir)
    on_exit(fn -> Uniops.Workspace.destroy(workspace) end)
    %{workspace: workspace}
  end

  describe "run_file/3" do
    test "executes a Unison function from a .u file and captures stdout", %{workspace: ws} do
      source = """
      myMain : '{IO, Exception} ()
      myMain = do printLine "hello from uniops"
      """

      {:ok, file_path} = Uniops.Workspace.write_source(ws, "hello.u", source)

      assert {:ok, result} = Uniops.Runner.run_file(file_path, "myMain", codebase: ws.path)
      assert result.stdout =~ "hello from uniops"
      assert result.exit_code == 0
    end

    test "returns error for code that fails to typecheck", %{workspace: ws} do
      source = """
      broken : Nat
      broken = "not a nat"
      """

      {:ok, file_path} = Uniops.Workspace.write_source(ws, "broken.u", source)

      assert {:error, result} = Uniops.Runner.run_file(file_path, "broken", codebase: ws.path)
      assert result.exit_code != 0
    end
  end

  describe "run_compiled/2" do
    test "executes a .uc bytecode file and captures stdout", %{workspace: ws} do
      source = """
      myMain : '{IO, Exception} ()
      myMain = do printLine "compiled hello"
      """

      {:ok, file_path} = Uniops.Workspace.write_source(ws, "compiled_test.u", source)
      {:ok, uc_path} = Uniops.Compiler.compile(ws, file_path, "myMain", "compiled_test")

      assert {:ok, result} = Uniops.Runner.run_compiled(uc_path)
      assert result.stdout =~ "compiled hello"
      assert result.exit_code == 0
    end
  end
end
