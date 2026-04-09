defmodule Unex.Services do
  @moduledoc """
  Public API for deploying, calling, listing, and undeploying named services.

  A service is a compiled Unison program registered under a human-readable name.
  """

  alias Unex.Services.Registry
  alias Unex.Services.Registry.Entry
  alias Unex.Cluster.HashCache
  alias Unex.Remote

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

  @doc """
  Points a service name at an existing bytecode hash.

  This is how versioning and rollback work: `deploy` uploads bytecode and
  returns a hash; `release` moves the name pointer to any existing hash.

  Returns `:ok` unconditionally — the hash need not exist yet.
  """
  def release(name, hash) do
    {:ok, _entry} = Registry.register(name, hash, node())
    :ok
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
    dir = Path.join(System.tmp_dir!(), "unex_svc_#{System.unique_integer([:positive])}")

    with {:ok, workspace} <- Unex.Workspace.create(dir),
         {:ok, file_path} <- Unex.Workspace.write_source(workspace, "service.u", source),
         {:ok, uc_path} <- Unex.Compiler.compile(workspace, file_path, entry_point, "service") do
      uc_bytes = File.read!(uc_path)
      Unex.Workspace.destroy(workspace)
      {:ok, uc_bytes}
    else
      error ->
        # Clean up workspace on error if it was created
        if File.dir?(dir), do: File.rm_rf!(dir)
        error
    end
  end
end
