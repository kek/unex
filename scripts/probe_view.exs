#!/usr/bin/env elixir

# Probe UCM for the right command to resolve a hash in our runtime codebase.
# Usage: mix run --no-start scripts/probe_view.exs <hash>

defmodule Probe do
  def collect(port, acc) do
    receive do
      {^port, {:data, data}} -> collect(port, acc <> data)
      {^port, {:exit_status, _}} -> acc
    after
      15_000 ->
        Port.close(port)
        acc
    end
  end

  def try_cmd(ucm, codebase_path, label, cmd) do
    IO.puts("\n========== #{label} ==========")
    IO.puts("CMD: #{inspect(cmd)}")

    port =
      Port.open({:spawn_executable, ucm}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["--codebase", codebase_path]
      ])

    send(port, {self(), {:command, cmd <> "exit\n"}})
    output = collect(port, "")

    blocks = Unex.Runtime.ucm_output_blocks(output)
    IO.puts("blocks: #{length(blocks)}")

    for {block, i} <- Enum.with_index(blocks) do
      IO.puts("--- block #{i} (#{byte_size(block)} bytes) ---")
      IO.puts(String.slice(block, 0, 600))
    end
  end
end

[hash | _] = System.argv()
IO.puts("Probing hash: #{hash}")

{:ok, ucm} = Unex.UCM.find()
codebase_path = Path.expand(Path.join("data", "runtime_codebase"))

commands = [
  {"find #hash", "find #{hash}\n"},
  {"ls current", "ls\n"},
  {"cd runtime && ls", "cd runtime\nls\n"},
  {"help view", "help view\n"},
  {"view bare", "view #{hash}\n"},
  {"project.switch runtime/main then view", "project.switch runtime/main\nview #{hash}\n"},
  {"project.switch @kek/counter/main then view",
   "project.switch @kek/counter/main\nview #{hash}\n"},
  {"display bare", "display #{hash}\n"},
  {"project.switch runtime/main then display", "project.switch runtime/main\ndisplay #{hash}\n"},
  {"names bare", "names #{hash}\n"},
  {"names.global bare", "names.global #{hash}\n"},
  {"dependencies", "dependencies #{hash}\n"},
  {"view with .0 suffix", "view #{hash}.0\n"},
  {"edit.hash", "edit.hash #{hash}\n"}
]

for {label, cmd} <- commands do
  Probe.try_cmd(ucm, codebase_path, label, cmd)
end
