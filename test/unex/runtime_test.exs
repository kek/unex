defmodule Unex.RuntimeTest do
  use ExUnit.Case, async: true

  # UCM does not echo commands to stdout — it prints a prompt line, reads a
  # command silently, then prints that command's output. Our test fixtures
  # mimic that: each prompt line is bare (`scratch/main>` followed only by
  # whitespace), and what appears BETWEEN prompts is one command's output.
  describe "parse_all_view_outputs/2" do
    test "zips each hash with its corresponding view-output block in order" do
      output = """
      Welcome banner line 1
      Welcome banner line 2
      scratch/main>\s
        foo : Nat
        foo = 42
      scratch/main>\s
        bar : Text
        bar = "hello"
      scratch/main>\s
        baz : Nat -> Nat
        baz n = n + 1
      scratch/main>\s
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
      banner
      scratch/main>\s
        foo : Nat
        foo = 42
      scratch/main>\s
      scratch/main>\s
      """

      result = Unex.Runtime.parse_all_view_outputs(output, ["#aaa111", "#bbb222"])

      assert Map.has_key?(result, "aaa111")
      refute Map.has_key?(result, "bbb222")
    end

    test "skips hashes whose view block is an error message" do
      output = """
      banner
      scratch/main>\s
        foo : Nat
        foo = 42
      scratch/main>\s
        ⚠️
        I don't know about that name.
      scratch/main>\s
      """

      result = Unex.Runtime.parse_all_view_outputs(output, ["#aaa111", "#missing"])

      assert Map.has_key?(result, "aaa111")
      refute Map.has_key?(result, "missing")
    end

    test "normalizes the leading #, so keys are the bare hash" do
      output = """
      banner
      .>\s
        x : Nat
        x = 1
      .>\s
      """

      result = Unex.Runtime.parse_all_view_outputs(output, ["#abc123"])

      assert Map.keys(result) == ["abc123"]
    end

    test "strips ANSI color escape sequences before parsing" do
      # UCM embeds ANSI escapes around prompts and identifiers.
      esc = "\e"

      output =
        "banner\n" <>
          "#{esc}[32mscratch#{esc}[0m#{esc}[90m/#{esc}[0m#{esc}[34mmain#{esc}[0m> \n" <>
          "  #{esc}[95mfoo#{esc}[0m : Nat\n" <>
          "  foo = 42\n" <>
          "#{esc}[32mscratch#{esc}[0m#{esc}[90m/#{esc}[0m#{esc}[34mmain#{esc}[0m> \n"

      result = Unex.Runtime.parse_all_view_outputs(output, ["#abc"])

      assert Map.has_key?(result, "abc")
      assert result["abc"] =~ "foo : Nat"
      assert result["abc"] =~ "foo = 42"
      refute result["abc"] =~ "\e["
    end

    test "returns an empty map when no hashes are given" do
      assert Unex.Runtime.parse_all_view_outputs("irrelevant", []) == %{}
    end
  end

  describe "parse_view_output/2" do
    test "returns the last non-empty output block from a pull/load/run/view transcript" do
      output = """
      banner
      runtime/main>\s
        (pull output)
      runtime/main>\s
        (load output)
      runtime/main>\s
        ()
      runtime/main>\s
        mainCounter : '{IO, Exception} ()
        mainCounter = Unex.main counter
      runtime/main>\s
      """

      result = Unex.Runtime.parse_view_output(output, "mainCounter")

      assert result =~ "mainCounter : '{IO, Exception} ()"
      assert result =~ "mainCounter = Unex.main counter"
    end

    test "returns nil when there are no output blocks" do
      assert Unex.Runtime.parse_view_output("banner with no prompts here", "anything") == nil
    end
  end
end
