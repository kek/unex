#!/usr/bin/env elixir
# Probe `find` variants to list all named terms in the deployed project.

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
      IO.puts(String.slice(block, 0, 1500))
    end
  end
end

{:ok, ucm} = Unex.UCM.find()
codebase_path = Path.expand(Path.join("data", "runtime_codebase"))

commands = [
  {"find (no args)", "find\n"},
  {"find Unex.", "find Unex.\n"},
  {"find counter.", "find counter.\n"},
  {"find-in counter", "find-in counter\n"},
  {"find-in counter.", "find-in counter.\n"},
  {"ls Unex", "ls Unex\n"},
  {"ls Unex.", "ls Unex.\n"},
  {"ls counter.", "ls counter.\n"},
  {"find.all", "find.all\n"},
  {"help find-in", "help find-in\n"}
]

for {label, cmd} <- commands do
  Probe.try_cmd(ucm, codebase_path, label, cmd)
end
