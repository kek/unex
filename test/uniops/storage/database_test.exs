defmodule Uniops.Storage.DatabaseTest do
  use ExUnit.Case, async: false

  alias Uniops.Storage.{Schema, Database}

  setup do
    dir = Path.join(System.tmp_dir!(), "uniops_db_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Schema.init(dir)

    on_exit(fn ->
      :mnesia.stop()
      File.rm_rf!(dir)
    end)

    :ok
  end

  test "create/1 returns :ok" do
    assert :ok = Database.create("mydb")
  end

  test "create/1 is idempotent" do
    assert :ok = Database.create("mydb")
    assert :ok = Database.create("mydb")
  end

  test "exists?/1 returns false for non-existent database" do
    assert Database.exists?("nope") == false
  end

  test "exists?/1 returns true after create" do
    Database.create("mydb")
    assert Database.exists?("mydb") == true
  end

  test "list/0 returns created database names" do
    Database.create("alpha")
    Database.create("beta")
    names = Database.list()
    assert "alpha" in names
    assert "beta" in names
  end
end
