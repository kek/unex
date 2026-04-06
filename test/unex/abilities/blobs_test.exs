defmodule Unex.Abilities.BlobsTest do
  use ExUnit.Case, async: false

  alias Unex.Abilities.Blobs

  setup do
    dir = Path.join(System.tmp_dir!(), "unex_blobs_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  describe "write/4 and read/3" do
    test "stores and retrieves binary data", %{dir: dir} do
      data = <<0, 1, 2, 255, 128>>
      assert :ok = Blobs.write(dir, "mydb", "images/photo.jpg", data)
      assert {:ok, ^data} = Blobs.read(dir, "mydb", "images/photo.jpg")
    end

    test "returns :not_found for missing blob", %{dir: dir} do
      assert :not_found = Blobs.read(dir, "mydb", "nope")
    end

    test "overwrites existing blob", %{dir: dir} do
      Blobs.write(dir, "mydb", "file", "v1")
      Blobs.write(dir, "mydb", "file", "v2")
      assert {:ok, "v2"} = Blobs.read(dir, "mydb", "file")
    end
  end

  describe "delete/3" do
    test "removes a blob", %{dir: dir} do
      Blobs.write(dir, "mydb", "temp", "data")
      assert :ok = Blobs.delete(dir, "mydb", "temp")
      assert :not_found = Blobs.read(dir, "mydb", "temp")
    end
  end

  describe "list/3" do
    test "lists blobs by prefix", %{dir: dir} do
      Blobs.write(dir, "mydb", "images/a.jpg", "a")
      Blobs.write(dir, "mydb", "images/b.jpg", "b")
      Blobs.write(dir, "mydb", "docs/readme.md", "c")

      keys = Blobs.list(dir, "mydb", "images/")
      assert "images/a.jpg" in keys
      assert "images/b.jpg" in keys
      refute "docs/readme.md" in keys
    end

    test "returns empty list for no matches", %{dir: dir} do
      assert [] = Blobs.list(dir, "mydb", "nothing/")
    end
  end
end
