defmodule LLMDB.SnapshotBuilderInstallTest do
  use ExUnit.Case, async: false

  alias LLMDB.Snapshot
  alias LLMDB.Snapshot.Builder

  @fixture_path "test/fixtures/snapshots/catalog-v1.json"

  test "local installation does not change the tracked source snapshot" do
    test_dir =
      Path.join(
        System.tmp_dir!(),
        "llm-db-runtime-install-#{System.unique_integer([:positive])}"
      )

    source_before = File.read!(Snapshot.source_packaged_path())

    on_exit(fn -> File.rm_rf!(test_dir) end)

    snapshot = @fixture_path |> File.read!() |> Jason.decode!()

    artifact = %{
      snapshot: snapshot,
      snapshot_id: snapshot["snapshot_id"],
      schema_version: Snapshot.schema_version(),
      metadata: %{"snapshot_id" => snapshot["snapshot_id"]},
      output_dir: test_dir,
      snapshot_path: Path.join(test_dir, "snapshot.json"),
      metadata_path: Path.join(test_dir, "snapshot-meta.json")
    }

    Builder.write!(artifact, install: true)

    assert File.exists?(artifact.snapshot_path)
    assert File.read!(Snapshot.source_packaged_path()) == source_before
    assert Builder.up_to_date?(artifact, install: true)
  end
end
