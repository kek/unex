defmodule Uniops.Storage.SchemaTest do
  use ExUnit.Case, async: false

  alias Uniops.Storage.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "uniops_schema_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      :mnesia.stop()
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  test "init/1 initializes Mnesia with disk storage", %{dir: dir} do
    assert :ok = Schema.init(dir)
    assert :mnesia.system_info(:is_running) == :yes
    assert :mnesia.system_info(:use_dir) == true
  end

  test "init/1 is idempotent", %{dir: dir} do
    assert :ok = Schema.init(dir)
    assert :ok = Schema.init(dir)
    assert :mnesia.system_info(:is_running) == :yes
  end

  test "init/1 creates the registry table", %{dir: dir} do
    Schema.init(dir)
    assert :uniops_registry in :mnesia.system_info(:tables)
  end
end
