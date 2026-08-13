defmodule Mix.Tasks.LlmDb.Npm.Export do
  use Mix.Task

  alias LLMDB.NPM.Exporter

  @shortdoc "Export the canonical snapshot as NPM provider shards"

  @moduledoc """
  Exports the canonical packaged snapshot into provider shards for the NPM
  workspace.

      mix llm_db.npm.export
      mix llm_db.npm.export --output packages/llmdb/generated
  """

  @switches [output: :string]

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if positional != [] or invalid != [] do
      Mix.raise("usage: mix llm_db.npm.export [--output DIR]")
    end

    output = Keyword.get(opts, :output, "packages/llmdb/generated")
    manifest = Exporter.export!(output)

    Mix.shell().info(
      "Exported #{manifest["provider_count"]} provider shards " <>
        "with #{manifest["model_count"]} models to #{Path.expand(output)}"
    )
  end
end
