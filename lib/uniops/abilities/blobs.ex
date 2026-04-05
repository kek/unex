defmodule Uniops.Abilities.Blobs do
  @moduledoc """
  Binary object storage on the filesystem.
  Blobs are stored at `<base_dir>/<db>/<key>` with directory creation on write.
  """

  @doc "Writes binary data to a blob."
  def write(base_dir, db, key, data) when is_binary(data) do
    path = blob_path(base_dir, db, key)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, data)
    :ok
  end

  @doc "Reads a blob. Returns `{:ok, data}` or `:not_found`."
  def read(base_dir, db, key) do
    path = blob_path(base_dir, db, key)

    case File.read(path) do
      {:ok, data} -> {:ok, data}
      {:error, :enoent} -> :not_found
    end
  end

  @doc "Deletes a blob."
  def delete(base_dir, db, key) do
    path = blob_path(base_dir, db, key)
    File.rm(path)
    :ok
  end

  @doc "Lists blob keys matching a prefix."
  def list(base_dir, db, prefix) do
    db_dir = Path.join([base_dir, db])

    if File.dir?(db_dir) do
      db_dir
      |> list_files_recursive()
      |> Enum.map(fn path -> Path.relative_to(path, db_dir) end)
      |> Enum.filter(&String.starts_with?(&1, prefix))
    else
      []
    end
  end

  defp blob_path(base_dir, db, key) do
    Path.join([base_dir, db, key])
  end

  defp list_files_recursive(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          path = Path.join(dir, entry)

          if File.dir?(path) do
            list_files_recursive(path)
          else
            [path]
          end
        end)

      {:error, _} ->
        []
    end
  end
end
