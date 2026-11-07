defmodule Mix.Tasks.LlmDb.Build do
  use Mix.Task
  @dialyzer {:nowarn_function, run: 1}

  alias LLMDB.Snapshot.Builder

  @shortdoc "Build a canonical snapshot artifact from configured sources"

  @moduledoc """
  Builds a canonical `snapshot.json` from configured sources.

  The snapshot is always written to a local build output directory. Use
  `--install` is a safe local-install alias that keeps all output under
  `_build`. The serialized integration and release workflows use
  `--install-source` to also update the tracked source snapshot.

  ## Usage

      mix llm_db.build
      mix llm_db.build --install
      mix llm_db.build --install-source
      mix llm_db.build --check
      mix llm_db.build --verify
      mix llm_db.build --output-dir tmp/llm_db/build
      mix llm_db.build --schema-version 2

  ## Options

    * `--check` - Verify the generated snapshot artifacts already match the
      expected output.
    * `--install` - Keep the built snapshot under `_build`. This safe local
      option does not change the tracked source snapshot.
    * `--install-source` - Also install the built snapshot into the tracked
      source snapshot. This option is for serialized integration and release
      automation.
    * `--verify` - Write a local build artifact, read it with strict integrity,
      rebuild from the same inputs, and require the same semantic snapshot ID.
    * `--output-dir` - Directory for local snapshot build artifacts.
    * `--schema-version` - Snapshot wire schema to build (`1` by default; `2`
      opts into a side-by-side sparse artifact). Sparse v2 cannot be installed as
      the packaged default in this minor release.
  """

  @impl Mix.Task
  def run(args) do
    ensure_llm_db_project!()

    {opts, _, invalid} =
      OptionParser.parse(args,
        strict: [
          check: :boolean,
          install: :boolean,
          install_source: :boolean,
          verify: :boolean,
          output_dir: :string,
          schema_version: :integer
        ]
      )

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    schema_version = opts[:schema_version] || LLMDB.Snapshot.schema_version()
    validate_schema_version!(schema_version, opts)
    validate_mode!(opts)

    Mix.Task.run("app.start")

    build_opts =
      []
      |> maybe_put(:output_dir, opts[:output_dir])
      |> Keyword.put(:schema_version, schema_version)

    Mix.shell().info("Building canonical snapshot from configured sources...\n")

    case Builder.build(build_opts) do
      {:ok, artifact} ->
        if opts[:verify] do
          verify!(artifact, build_opts)
        else
          maybe_check_or_write(artifact, opts)
        end

      {:error, reason} ->
        Mix.raise("Snapshot build failed: #{inspect(reason)}")
    end
  end

  defp maybe_check_or_write(artifact, opts) do
    if opts[:check] do
      if Builder.up_to_date?(artifact, install_opts(opts)) do
        Mix.shell().info("✓ Snapshot artifacts are up to date.")
      else
        expected_paths =
          expected_paths(artifact, opts)

        Mix.raise("""
        Snapshot artifacts are out of date.

        Expected:
        #{Enum.map_join(expected_paths, "\n", &"  - #{&1}")}

        To fix this:
          mix llm_db.build#{install_suffix(opts)}
        """)
      end
    else
      artifact = Builder.write!(artifact, install_opts(opts))
      print_summary(artifact, opts)
    end
  end

  defp print_summary(artifact, opts) do
    counts = LLMDB.Snapshot.counts(artifact.snapshot)

    Mix.shell().info("✓ Snapshot written to #{artifact.snapshot_path}")
    Mix.shell().info("✓ Metadata written to #{artifact.metadata_path}")

    if opts[:install] do
      Mix.shell().info("✓ Local snapshot kept under #{artifact.output_dir}")
    end

    if opts[:install_source] do
      Mix.shell().info("✓ Source snapshot installed to #{LLMDB.Snapshot.source_packaged_path()}")
    end

    Mix.shell().info("")
    Mix.shell().info("Summary:")
    Mix.shell().info("  Snapshot ID: #{artifact.snapshot_id}")
    Mix.shell().info("  Schema:      v#{artifact.schema_version}")
    Mix.shell().info("  Providers:   #{counts.provider_count}")
    Mix.shell().info("  Models:      #{counts.model_count}")
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp install_opts(opts) do
    [install_source: opts[:install_source] == true]
  end

  defp install_suffix(opts) do
    cond do
      opts[:install_source] -> " --install-source"
      opts[:install] -> " --install"
      true -> ""
    end
  end

  defp expected_paths(artifact, opts) do
    if opts[:install_source] do
      [LLMDB.Snapshot.source_packaged_path()]
    else
      [artifact.snapshot_path, artifact.metadata_path]
    end
  end

  defp verify!(artifact, build_opts) do
    artifact = Builder.write!(artifact)

    with {:ok, strict_snapshot} <-
           LLMDB.Snapshot.read(artifact.snapshot_path, integrity_policy: :strict),
         true <- strict_snapshot["snapshot_id"] == artifact.snapshot_id,
         {:ok, rebuilt} <- Builder.build(build_opts),
         true <- rebuilt.snapshot_id == artifact.snapshot_id do
      Mix.shell().info("✓ Catalog is strict and semantically reproducible.")
      Mix.shell().info("  Snapshot ID: #{artifact.snapshot_id}")
    else
      false -> Mix.raise("Catalog verification produced a different semantic snapshot ID")
      {:error, reason} -> Mix.raise("Catalog verification failed: #{inspect(reason)}")
    end
  end

  defp validate_mode!(opts) do
    if opts[:install] == true and opts[:install_source] == true do
      Mix.raise("--install cannot be combined with --install-source")
    end

    if opts[:verify] == true and
         (opts[:check] == true or opts[:install] == true or opts[:install_source] == true) do
      Mix.raise("--verify cannot be combined with --check, --install, or --install-source")
    end
  end

  defp validate_schema_version!(schema_version, opts) do
    unless schema_version in LLMDB.Snapshot.supported_schema_versions() do
      Mix.raise(
        "Unsupported snapshot schema version #{inspect(schema_version)}; expected one of #{inspect(LLMDB.Snapshot.supported_schema_versions())}"
      )
    end

    if schema_version == LLMDB.Snapshot.sparse_schema_version() and
         opts[:install_source] == true do
      Mix.raise(
        "Sparse snapshot schema v#{schema_version} is opt-in and cannot be installed as the packaged default in this minor release"
      )
    end
  end

  defp ensure_llm_db_project! do
    app = Mix.Project.config()[:app]

    if app != :llm_db do
      Mix.raise("""
      mix llm_db.build can only be run inside the llm_db project itself.
      """)
    end
  end
end
