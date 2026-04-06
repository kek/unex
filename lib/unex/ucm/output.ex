defmodule Unex.UCM.Output do
  @moduledoc """
  Shared UCM output parsing — detects errors and strips ANSI codes.

  UCM exits 0 even on typecheck/lookup failures, so we detect errors
  by inspecting the output content.
  """

  @error_patterns [
    "I found a value  of type:",
    "I couldn't resolve any of",
    "couldn't find one",
    "parse error",
    "Type error",
    "There's nothing for me to add"
  ]

  @doc """
  Returns true if UCM output indicates an error.
  """
  def error?(output) do
    stripped = strip_ansi(output)
    Enum.any?(@error_patterns, &String.contains?(stripped, &1))
  end

  @doc """
  Strips ANSI escape sequences from text.
  """
  def strip_ansi(text) do
    Regex.replace(~r/\e\[[0-9;]*m/, text, "")
  end
end
