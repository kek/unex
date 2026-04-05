defmodule Uniops.Services do
  @moduledoc """
  Public API for deploying, calling, listing, and undeploying named services.

  A service is a compiled Unison program registered under a human-readable name.
  """

  alias Uniops.Services.Registry
  alias Uniops.Services.Registry.Entry
  alias Uniops.Cluster.HashCache
  alias Uniops.Remote

  @doc """
  Compiles source code, caches the bytecode, and registers it as a named service.

  Options:
    - `:entry` — the entry point symbol (default: `"main"`)

  Returns `{:ok, %Entry{}}` on success or `{:error, reason}` on failure.
  """
  def deploy(name, source, opts \\ []) do
    entry_point = Keyword.get(opts, :entry, "main")

    with {:ok, uc_bytes} <- compile_source(source, entry_point) do
      hash = HashCache.put(uc_bytes)
      Registry.register(name, hash, node())
    end
  end

  @doc """
  Calls a named service by resolving its registry entry and executing its bytecode.

  Options are forwarded to `Remote.execute/2`.

  Returns the execution result or `{:error, :not_found}`.
  """
  def call(name, opts \\ []) do
    case Registry.resolve(name) do
      {:ok, %Entry{} = entry} ->
        Remote.execute(entry.hash, opts)

      :not_found ->
        {:error, :not_found}
    end
  end

  @doc "Lists all registered services."
  def list do
    Registry.list()
  end

  @doc "Unregisters a named service."
  def undeploy(name) do
    Registry.unregister(name)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp compile_source(source, entry_point) do
    dir = Path.join(System.tmp_dir!(), "uniops_svc_#{System.unique_integer([:positive])}")

    with {:ok, workspace} <- Uniops.Workspace.create(dir),
         {:ok, file_path} <- Uniops.Workspace.write_source(workspace, "service.u", source),
         {:ok, uc_path} <- Uniops.Compiler.compile(workspace, file_path, entry_point, "service") do
      uc_bytes = File.read!(uc_path)
      Uniops.Workspace.destroy(workspace)
      {:ok, uc_bytes}
    else
      error ->
        # Clean up workspace on error if it was created
        if File.dir?(dir), do: File.rm_rf!(dir)
        error
    end
  end
end
