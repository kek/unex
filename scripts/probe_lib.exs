#!/usr/bin/env elixir

defmodule Probe do
  def collect(port, acc) do
    receive do
      {^port, {:data, data}} -> collect(port, acc <> data)
      {^port, {:exit_status, _}} -> acc
    after
      30_000 ->
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
      IO.puts(String.slice(block, 0, 800))
    end
  end
end

{:ok, ucm} = Unex.UCM.find()
codebase_path = Path.expand(Path.join("data", "runtime_codebase"))

[
  {"ls lib", "ls lib\n"},
  {"find-in lib.kek_unex_0_1_1", "find-in lib.kek_unex_0_1_1\n"}
]
|> Enum.each(fn {label, cmd} -> Probe.try_cmd(ucm, codebase_path, label, cmd) end)
