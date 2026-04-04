defmodule Uniops.Integration.EndToEndTest do
  use ExUnit.Case, async: false

  describe "eval/2" do
    test "evaluates Unison source code and returns stdout" do
      source = """
      main : '{IO, Exception} ()
      main = do printLine "42"
      """

      assert {:ok, result} = Uniops.eval(source)
      assert result.stdout =~ "42"
    end

    test "evaluates with custom entry point" do
      source = """
      greet : '{IO, Exception} ()
      greet = do printLine "hi there"
      """

      assert {:ok, result} = Uniops.eval(source, entry: "greet")
      assert result.stdout =~ "hi there"
    end
  end

  describe "compile_and_run/2" do
    test "compiles to bytecode and executes it" do
      source = """
      main : '{IO, Exception} ()
      main = do printLine "bytecode works"
      """

      assert {:ok, result} = Uniops.compile_and_run(source)
      assert result.stdout =~ "bytecode works"
    end
  end
end
