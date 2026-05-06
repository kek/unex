defmodule Mix.Tasks.Docs.Pdf do
  @moduledoc """
  Regenerates the documentation PDFs in `docs/pdf/` from the Markdown
  sources in `docs/`.

  Each `docs/<name>.md` is rendered to `docs/pdf/<name>.pdf` via `pandoc`
  using the `xelatex` PDF engine (the same toolchain the checked-in copies
  were built with). The PDFs themselves are generated artifacts and are
  git-ignored — run this task to (re)produce them locally.

      mix docs.pdf            # regenerate every docs/*.md
      mix docs.pdf guide      # regenerate only docs/guide.md

  Requires `pandoc` and `xelatex` on PATH.
  """

  use Mix.Task

  @shortdoc "Regenerate docs/pdf/*.pdf from docs/*.md via pandoc"

  @src_dir "docs"
  @out_dir "docs/pdf"
  @pdf_engine "xelatex"

  @impl Mix.Task
  def run(args) do
    ensure_executable!("pandoc")
    ensure_executable!(@pdf_engine)

    File.mkdir_p!(@out_dir)

    sources =
      case args do
        [] -> Path.wildcard(Path.join(@src_dir, "*.md"))
        names -> Enum.map(names, &Path.join(@src_dir, Path.rootname(&1, ".md") <> ".md"))
      end

    if sources == [] do
      Mix.raise("No Markdown sources found under #{@src_dir}/")
    end

    Enum.each(sources, &render/1)

    Mix.shell().info("Done — #{length(sources)} PDF(s) written to #{@out_dir}/")
  end

  defp render(src) do
    unless File.exists?(src) do
      Mix.raise("Source not found: #{src}")
    end

    out = Path.join(@out_dir, Path.basename(src, ".md") <> ".pdf")
    Mix.shell().info("#{src} -> #{out}")

    case System.cmd("pandoc", [src, "-o", out, "--pdf-engine=#{@pdf_engine}"],
           stderr_to_stdout: true
         ) do
      {_out, 0} ->
        :ok

      {output, status} ->
        Mix.raise("pandoc failed for #{src} (exit #{status}):\n#{output}")
    end
  end

  defp ensure_executable!(name) do
    unless System.find_executable(name) do
      Mix.raise("`#{name}` not found on PATH — required to build the docs PDFs")
    end
  end
end
