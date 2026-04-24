defmodule Unex.Dashboard.BoundaryTest do
  use ExUnit.Case, async: true

  @core_root "lib/unex"
  @dashboard_namespace "Unex.Dashboard"
  # Allow-listed symbol: core may publish events via this one module only.
  @allowed "Unex.Dashboard.Events"

  test "core does not reference the dashboard namespace except Events" do
    offenders =
      Path.wildcard("#{@core_root}/**/*.ex")
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _} ->
          String.contains?(line, @dashboard_namespace) and
            not String.contains?(line, @allowed)
        end)
        |> Enum.map(fn {line, n} -> "#{path}:#{n}: #{String.trim(line)}" end)
      end)

    assert offenders == [], """
    Boundary violation: files under #{@core_root} reference #{@dashboard_namespace}.
    Only #{@allowed} is permitted. Offenders:

    #{Enum.join(offenders, "\n")}
    """
  end
end
