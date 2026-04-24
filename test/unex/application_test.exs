defmodule Unex.ApplicationTest do
  use ExUnit.Case, async: false

  test "Phoenix.PubSub is running under the Unex supervisor" do
    assert is_pid(Process.whereis(Unex.PubSub))
  end

  test "dashboard supervisor not started when :start_dashboard is false" do
    assert Application.get_env(:unex, :start_dashboard) == false
    assert Process.whereis(Unex.Dashboard.Endpoint) == nil
  end
end
