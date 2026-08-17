defmodule Mix.Tasks.LlmDb.History.Rebuild do
  use Mix.Task
  @dialyzer {:nowarn_function, run: 1}

  alias LLMDB.{History.Bundle, History.Rebuilder, Snapshot.ReleaseStore}

  @shortdoc "Rebuild snapshot-based history artifacts from the published snapshot store"

  @moduledoc """
  Rebuilds local history artifacts from the published snapshot observation chain,
  then bundles the result and optionally publishes `history.tar.gz` plus
  `history-meta.json` to the mutable `history-latest` release.

  By default, the task installs the latest published checkpoint and processes
  only new snapshots. Use `--full` for an audit or repair rebuild.
  """

  @impl Mix.Task
  def run(args) do
    ensure_llm_db_project!()

    {opts, _, invalid} =
      OptionParser.parse(args,
        strict: [
          history_dir: :string,
          output_dir: :string,
          publish: :boolean,
          full: :boolean,
          repo: :string,
          index_tag: :string,
          cache_dir: :string
        ]
      )

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    store_overrides =
      []
      |> maybe_put(:repo, opts[:repo])
      |> maybe_put(:index_tag, opts[:index_tag])
      |> maybe_put(:cache_dir, opts[:cache_dir])

    history_dir = Bundle.history_dir(opts[:history_dir])
    full? = opts[:full] == true

    observations =
      case ReleaseStore.fetch_snapshot_index(store_overrides) do
        {:ok, snapshots} ->
          snapshots

        {:error, :not_found} ->
          Mix.raise("""
          History rebuild failed: no published snapshot index was found.

          Publish a snapshot first with:

              mix llm_db.snapshot.publish

          For an initial historical seed, use:

              mix llm_db.history.migrate_git --publish
          """)

        {:error, reason} ->
          Mix.raise("History rebuild failed: #{inspect(reason)}")
      end

    unless full? do
      install_published_checkpoint(history_dir, store_overrides)
    end

    indexed_store_overrides = Keyword.put(store_overrides, :snapshot_index, observations)
    load_count = :atomics.new(1, signed: false)

    snapshot_loader = fn snapshot_id ->
      count = :atomics.add_get(load_count, 1, 1)

      if count == 1 or rem(count, 10) == 0 do
        Mix.shell().info("  processing snapshot #{count}: #{String.slice(snapshot_id, 0, 12)}")
      end

      case ReleaseStore.fetch_snapshot(snapshot_id, indexed_store_overrides) do
        {:ok, %{snapshot: snapshot}} -> {:ok, snapshot}
        {:error, reason} -> {:error, reason}
      end
    end

    with {:ok, summary} <-
           Rebuilder.rebuild(
             observations: observations,
             output_dir: history_dir,
             source: "github_releases",
             mode: if(full?, do: :full, else: :auto),
             snapshot_loader: snapshot_loader
           ) do
      if summary.snapshots_processed == 0 do
        Mix.shell().info("✓ History is already current")
        Mix.shell().info("  snapshots: #{summary.snapshots_written}")
        Mix.shell().info("  events:    #{summary.events_written}")
      else
        bundle_opts =
          []
          |> Keyword.put(:history_dir, history_dir)
          |> Keyword.put(:snapshot_index, observations)
          |> maybe_put(:output_dir, opts[:output_dir])

        case Bundle.bundle(bundle_opts) do
          {:ok, bundle} ->
            history_release_tag =
              if opts[:publish] do
                to_snapshot_id =
                  summary.to_snapshot_id ||
                    raise "History rebuild failed: missing to_snapshot_id for publish"

                case ReleaseStore.publish_history_release(
                       [bundle.archive_path, bundle.metadata_path],
                       to_snapshot_id,
                       store_overrides
                     ) do
                  {:ok, tag} -> tag
                  {:error, reason} -> Mix.raise("History rebuild failed: #{inspect(reason)}")
                end
              end

            Mix.shell().info("✓ History rebuilt")
            Mix.shell().info("  history dir: #{summary.output_dir}")
            Mix.shell().info("  archive:     #{bundle.archive_path}")
            Mix.shell().info("  metadata:    #{bundle.metadata_path}")
            Mix.shell().info("  snapshots:   #{summary.snapshots_written}")
            Mix.shell().info("  processed:   #{summary.snapshots_processed} (#{summary.mode})")
            Mix.shell().info("  events:      #{summary.events_written}")
            Mix.shell().info("  events added: #{summary.events_added}")

            if opts[:publish] do
              Mix.shell().info("  published history release: #{history_release_tag}")
            end

          {:error, reason} ->
            Mix.raise("History rebuild failed: #{inspect(reason)}")
        end
      end
    else
      {:error, reason} ->
        Mix.raise("History rebuild failed: #{inspect(reason)}")
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp install_published_checkpoint(history_dir, store_overrides) do
    archive_path =
      Path.join(
        System.tmp_dir!(),
        "llm_db-history-checkpoint-#{System.unique_integer([:positive])}.tar.gz"
      )

    case ReleaseStore.download_history_archive(archive_path, store_overrides) do
      :ok ->
        case Bundle.install_archive(archive_path, history_dir) do
          :ok -> Mix.shell().info("✓ Installed latest history checkpoint")
          {:error, reason} -> Mix.raise("History checkpoint install failed: #{inspect(reason)}")
        end

      {:error, :not_found} ->
        Mix.shell().info("No published history checkpoint found; using a full rebuild")

      {:error, reason} ->
        Mix.raise("History checkpoint download failed: #{inspect(reason)}")
    end

    File.rm(archive_path)
    :ok
  end

  defp ensure_llm_db_project! do
    app = Mix.Project.config()[:app]

    if app != :llm_db do
      Mix.raise("""
      mix llm_db.history.rebuild can only be run inside the llm_db project itself.
      """)
    end
  end
end
