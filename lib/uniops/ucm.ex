defmodule Uniops.UCM do
  @moduledoc """
  Detects and validates the UCM (Unison Codebase Manager) binary.
  """

  @doc """
  Finds the UCM binary on PATH. Returns `{:ok, absolute_path}` or `{:error, :not_found}`.
  """
  def find(opts \\ []) do
    name = Keyword.get(opts, :name, configured_path())

    case System.find_executable(name) do
      nil -> {:error, :not_found}
      path -> {:ok, path}
    end
  end

  @doc """
  Returns the UCM version as `{:ok, version_string}` or `{:error, reason}`.
  """
  def version do
    with {:ok, path} <- find() do
      case System.cmd(path, ["--version"], stderr_to_stdout: true) do
        {output, 0} ->
          case Regex.run(~r/(\d+\.\d+\.\d+)/, output) do
            [_, version] -> {:ok, version}
            nil -> {:error, {:parse_error, output}}
          end

        {output, code} ->
          {:error, {:exit, code, output}}
      end
    end
  end

  @doc """
  Verifies UCM is available and returns :ok. Raises on failure.
  """
  def check! do
    case find() do
      {:ok, _path} -> :ok
      {:error, :not_found} -> raise "UCM not found on PATH. Install from https://www.unison-lang.org/docs/quickstart/"
    end
  end

  defp configured_path do
    Application.get_env(:uniops, :ucm_path, "ucm")
  end
end
