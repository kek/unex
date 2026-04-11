defmodule Unex.Executor do
  @moduledoc """
  Manages the executor.uc compiled program used to run deployed service bundles.

  On startup, checks for executor.uc at the configured data directory.
  If missing, attempts auto-compilation from unison/executor.u source.
  """

  use GenServer

  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the path to executor.uc, or {:error, reason} if not available."
  def executor_path(server \\ __MODULE__) do
    GenServer.call(server, :executor_path)
  end

  @impl true
  def init(_opts) do
    uc_path = Path.join(data_dir(), "executor.uc")

    state =
      if File.exists?(uc_path) do
        Logger.info("Executor ready: #{uc_path}")
        %{path: uc_path}
      else
        case try_compile(uc_path) do
          {:ok, path} ->
            Logger.info("Executor compiled: #{path}")
            %{path: path}

          {:error, reason} ->
            Logger.warning("""
            Executor not available: #{reason}

            To compile manually, run in a Unison project with @unison/base installed:
              load unison/executor.u
              add
              compile executor #{uc_path}
            """)

            %{path: nil}
        end
      end

    {:ok, state}
  end

  @impl true
  def handle_call(:executor_path, _from, %{path: nil} = state) do
    {:reply, {:error, :not_compiled}, state}
  end

  def handle_call(:executor_path, _from, %{path: path} = state) do
    {:reply, {:ok, path}, state}
  end

  defp try_compile(uc_path) do
    source = Path.join(source_dir(), "executor.u")

    unless File.exists?(source) do
      {:error, "executor.u source not found at #{source}"}
    else
      File.mkdir_p!(Path.dirname(uc_path))

      dir = Path.join(System.tmp_dir!(), "unex_executor_ws_#{System.unique_integer([:positive])}")

      case Unex.Workspace.create(dir) do
        {:ok, workspace} ->
          try do
            case Unex.Compiler.compile(workspace, source, "executor", Path.rootname(uc_path)) do
              {:ok, compiled_path} ->
                if compiled_path != uc_path do
                  File.cp!(compiled_path, uc_path)
                end

                {:ok, uc_path}

              {:error, reason} ->
                {:error, "compilation failed: #{inspect(reason)}"}
            end
          after
            Unex.Workspace.destroy(workspace)
          end

        {:error, reason} ->
          {:error, "workspace creation failed: #{inspect(reason)}"}
      end
    end
  end

  defp data_dir do
    Application.get_env(:unex, :data_dir, "data")
  end

  defp source_dir do
    Application.get_env(:unex, :source_dir, "unison")
  end
end
