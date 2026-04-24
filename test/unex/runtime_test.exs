defmodule Unex.RuntimeTest do
  use ExUnit.Case, async: true

  describe "parse_all_view_outputs/2" do
    test "extracts per-hash source blocks from a multi-view UCM output" do
      output = """
      scratch/main> view #aaa111

        foo : Nat
        foo = 42

      scratch/main> view #bbb222

        bar : Text
        bar = "hello"

      scratch/main> view #ccc333

        baz : Nat -> Nat
        baz n = n + 1

      scratch/main> exit
      """

      hashes = ["#aaa111", "#bbb222", "#ccc333"]
      result = Unex.Runtime.parse_all_view_outputs(output, hashes)

      assert Map.has_key?(result, "aaa111")
      assert Map.has_key?(result, "bbb222")
      assert Map.has_key?(result, "ccc333")

      assert result["aaa111"] =~ "foo : Nat"
      assert result["aaa111"] =~ "foo = 42"
      assert result["bbb222"] =~ "bar : Text"
      assert result["bbb222"] =~ ~s(bar = "hello")
      assert result["ccc333"] =~ "baz : Nat -> Nat"
      assert result["ccc333"] =~ "baz n = n + 1"
    end

    test "skips hashes whose view block is empty" do
      output = """
      scratch/main> view #aaa111

        foo : Nat
        foo = 42

      scratch/main> view #bbb222
      scratch/main> exit
      """

      result = Unex.Runtime.parse_all_view_outputs(output, ["#aaa111", "#bbb222"])

      assert Map.has_key?(result, "aaa111")
      refute Map.has_key?(result, "bbb222")
    end

    test "skips hashes whose view block is an error message" do
      output = """
      scratch/main> view #aaa111

        foo : Nat
        foo = 42

      scratch/main> view #missing

        ⚠️
        I don't know about that name.

      scratch/main> exit
      """

      result = Unex.Runtime.parse_all_view_outputs(output, ["#aaa111", "#missing"])

      assert Map.has_key?(result, "aaa111")
      refute Map.has_key?(result, "missing")
    end

    test "normalizes the leading #, so keys are the bare hash" do
      output = """
      .> view #abc123

        x : Nat
        x = 1

      .> exit
      """

      result = Unex.Runtime.parse_all_view_outputs(output, ["#abc123"])

      assert Map.keys(result) == ["abc123"]
    end

    test "returns an empty map when no hashes are given" do
      assert Unex.Runtime.parse_all_view_outputs("irrelevant", []) == %{}
    end

    test "returns an empty map when the hash isn't present in the output" do
      output = """
      scratch/main> view #aaa111
      scratch/main> exit
      """

      assert Unex.Runtime.parse_all_view_outputs(output, ["#notthere"]) == %{}
    end
  end
end
