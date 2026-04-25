#!/usr/bin/env elixir

# Probe UCM commands that go from a NAME to a hash, or list names+hashes.
# Usage: mix run --no-start scripts/probe_view.exs

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
      IO.puts(String.slice(block, 0, 800))
    end
  end
end

{:ok, ucm} = Unex.UCM.find()
codebase_path = Path.expand(Path.join("data", "runtime_codebase"))

# These commands should accept a NAME and return information including hash.
commands = [
  {"names mainCounter", "names mainCounter\n"},
  {"alias.list mainCounter", "alias.list mainCounter\n"},
  {"hashqualified mainCounter", "hashqualified mainCounter\n"},
  {"view mainCounter", "view mainCounter\n"},
  {"view.hash mainCounter", "view.hash mainCounter\n"},
  {"display mainCounter", "display mainCounter\n"},
  {"dependents mainCounter", "dependents mainCounter\n"},
  {"dependencies mainCounter", "dependencies mainCounter\n"},
  {"debug.numberedArgs", "view mainCounter\ndebug.numberedArgs\n"},
  {"debug.dump-namespace", "debug.dump-namespace\n"},
  {"help find", "help find\n"},
  {"help debug", "help debug\n"},
  {"find.verbose mainCounter", "find.verbose mainCounter\n"},
  {"reflog", "reflog\n"},
  {"history", "history\n"},
  # UCM transcript-style: tries to find the term by a fragment.
  {"find mainCounter", "find mainCounter\n"},
  # The hash of the entry we know works:
  {"view #2u7l1...", "view #2u7l1\n"},
  # And: try getting the hash via Unison code by termLink:
  {"load termlink probe", "load /tmp/probe_termlink.u\nrun probe.dumpHash\n"}
]

# Generate a tiny .u that emits the hash of mainCounter:
File.write!("/tmp/probe_termlink.u", """
probe.dumpHash : '{IO, Exception} ()
probe.dumpHash = do
  ref = termLink mainCounter
  printLine ("HASH=" Text.++ Link.Term.toText ref)
""")

for {label, cmd} <- commands do
  Probe.try_cmd(ucm, codebase_path, label, cmd)
end
