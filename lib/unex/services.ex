defmodule Unex.Services do
  @moduledoc """
  Public API for deploying, calling, listing, and undeploying named services.

  A service is a compiled Unison program registered under a human-readable name.
  """

  alias Unex.Services.Registry
  alias Unex.Services.Registry.Entry
  alias Unex.Remote

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

  This is how versioning and rollback work: bytecode is pushed via PUT /bytecode/:hash
  first, then `release` moves the name pointer to any existing hash.

  Returns `{:ok, %Entry{}}` on success.
  """
  def release(name, hash) do
    Registry.register(name, hash, node())
  end

  @doc "Lists all registered services."
  def list do
    Registry.list()
  end

  @doc "Unregisters a named service."
  def undeploy(name) do
    Registry.unregister(name)
  end

end
