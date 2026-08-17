defmodule LLMDB.History.BundleTest do
  use ExUnit.Case, async: true

  alias LLMDB.{History.Bundle, Snapshot}

  test "installs a checkpoint without stale generated files" do
    source_dir = temp_dir("llm_db_bundle_source")
    destination_dir = temp_dir("llm_db_bundle_destination")
    bundle_dir = temp_dir("llm_db_bundle_output")

    write_file(source_dir, "events/2026.ndjson", ~s({"event_id":"new"}\n))
    write_file(source_dir, "snapshots.ndjson", ~s({"snapshot_id":"new"}\n))
    write_json(source_dir, "meta.json", %{"to_snapshot_id" => "new", "event_count" => 1})
    write_json(source_dir, Snapshot.history_state_filename(), %{"to_snapshot_id" => "new"})
    write_json(source_dir, Snapshot.snapshot_index_filename(), %{"snapshots" => []})
    write_json(source_dir, Snapshot.latest_filename(), %{"snapshot_id" => "new"})

    write_file(destination_dir, "events/2025.ndjson", ~s({"event_id":"stale"}\n))
    write_file(destination_dir, ".incremental-transaction/manifest.json", "stale")
    write_json(destination_dir, Snapshot.history_state_filename(), %{"to_snapshot_id" => "old"})
    write_json(destination_dir, "lineage_overrides.json", %{"lineage" => %{}})

    assert {:ok, bundle} =
             Bundle.bundle(history_dir: source_dir, output_dir: bundle_dir)

    assert :ok = Bundle.install_archive(bundle.archive_path, destination_dir)

    refute File.exists?(Path.join(destination_dir, "events/2025.ndjson"))
    refute File.exists?(Path.join(destination_dir, ".incremental-transaction"))
    assert File.exists?(Path.join(destination_dir, "events/2026.ndjson"))

    assert read_json(destination_dir, Snapshot.history_state_filename())["to_snapshot_id"] ==
             "new"

    assert File.exists?(Path.join(destination_dir, "lineage_overrides.json"))
  end

  defp write_json(dir, path, value), do: write_file(dir, path, Jason.encode!(value))

  defp write_file(dir, path, value) do
    full_path = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, value)
  end

  defp read_json(dir, path) do
    dir
    |> Path.join(path)
    |> File.read!()
    |> Jason.decode!()
  end

  defp temp_dir(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
