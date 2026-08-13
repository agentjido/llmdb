defmodule LLMDB.Snapshot.ReleaseStoreTest do
  use ExUnit.Case, async: false

  alias LLMDB.Snapshot.ReleaseStore

  test "creates snapshot and history releases atomically with unique tags" do
    tmp_dir = tmp_dir("release_store_create")
    bin_dir = Path.join(tmp_dir, "bin")
    assets_dir = Path.join(tmp_dir, "assets")
    log_path = Path.join(tmp_dir, "gh.log")
    script_path = Path.join(bin_dir, "gh")
    original_path = System.get_env("PATH")

    {snapshot_path, snapshot_meta_path, history_archive_path, history_meta_path} =
      write_assets!(assets_dir)

    File.mkdir_p!(bin_dir)
    File.write!(script_path, gh_script(log_path))
    File.chmod!(script_path, 0o755)
    File.write!(log_path, "")
    System.put_env("PATH", "#{bin_dir}:#{original_path}")

    on_exit(fn ->
      System.put_env("PATH", original_path)
    end)

    assert {:ok, snapshot_tag} =
             ReleaseStore.ensure_snapshot_release(
               snapshot_path,
               snapshot_meta_path,
               "abc",
               snapshot_index: []
             )

    assert snapshot_tag =~ ~r/^snapshot-abc-\d+-\d+$/

    assert {:ok, history_tag} =
             ReleaseStore.publish_history_release(
               [history_archive_path, history_meta_path],
               "abc",
               history_entries: []
             )

    assert history_tag =~ ~r/^history-abc-\d+-\d+$/

    log = File.read!(log_path)
    assert log =~ "release create #{snapshot_tag} #{snapshot_path} #{snapshot_meta_path}"
    assert log =~ "release create #{history_tag} #{history_archive_path} #{history_meta_path}"
  end

  test "reuses already indexed snapshot and history releases" do
    tmp_dir = tmp_dir("release_store_reuse")
    bin_dir = Path.join(tmp_dir, "bin")
    assets_dir = Path.join(tmp_dir, "assets")
    log_path = Path.join(tmp_dir, "gh.log")
    script_path = Path.join(bin_dir, "gh")
    original_path = System.get_env("PATH")

    {snapshot_path, snapshot_meta_path, history_archive_path, history_meta_path} =
      write_assets!(assets_dir)

    File.mkdir_p!(bin_dir)
    File.write!(script_path, gh_script(log_path))
    File.chmod!(script_path, 0o755)
    File.write!(log_path, "")
    System.put_env("PATH", "#{bin_dir}:#{original_path}")

    on_exit(fn ->
      System.put_env("PATH", original_path)
    end)

    existing_snapshot_entry = %{
      "snapshot_id" => "abc",
      "tag" => "snapshot-abc-existing",
      "snapshot_url" => "https://example.test/snapshot.json",
      "snapshot_meta_url" => "https://example.test/snapshot-meta.json"
    }

    existing_history_entry = %{
      "to_snapshot_id" => "abc",
      "tag" => "history-abc-existing",
      "history_url" => "https://example.test/history.tar.gz",
      "history_meta_url" => "https://example.test/history-meta.json"
    }

    assert {:ok, "snapshot-abc-existing"} =
             ReleaseStore.ensure_snapshot_release(
               snapshot_path,
               snapshot_meta_path,
               "abc",
               snapshot_index: [existing_snapshot_entry]
             )

    assert {:ok, "history-abc-existing"} =
             ReleaseStore.publish_history_release(
               [history_archive_path, history_meta_path],
               "abc",
               history_entries: [existing_history_entry]
             )

    assert File.read!(log_path) == ""
  end

  test "creates a fresh unique snapshot release when only broken historical tags exist" do
    tmp_dir = tmp_dir("release_store_repair")
    bin_dir = Path.join(tmp_dir, "bin")
    assets_dir = Path.join(tmp_dir, "assets")
    log_path = Path.join(tmp_dir, "gh.log")
    script_path = Path.join(bin_dir, "gh")
    original_path = System.get_env("PATH")

    {snapshot_path, snapshot_meta_path, _history_archive_path, _history_meta_path} =
      write_assets!(assets_dir)

    File.mkdir_p!(bin_dir)
    File.write!(script_path, gh_script(log_path))
    File.chmod!(script_path, 0o755)
    System.put_env("PATH", "#{bin_dir}:#{original_path}")

    on_exit(fn ->
      System.put_env("PATH", original_path)
    end)

    assert {:ok, snapshot_tag} =
             ReleaseStore.ensure_snapshot_release(
               snapshot_path,
               snapshot_meta_path,
               "abc",
               snapshot_index: []
             )

    assert snapshot_tag =~ ~r/^snapshot-abc-\d+-\d+$/
    refute snapshot_tag == "snapshot-abc"

    log = File.read!(log_path)
    assert log =~ "release create #{snapshot_tag} #{snapshot_path} #{snapshot_meta_path}"
    refute log =~ "release delete"
    refute log =~ "release upload"
  end

  defp write_assets!(assets_dir) do
    File.mkdir_p!(assets_dir)

    snapshot_path = Path.join(assets_dir, "snapshot.json")
    snapshot_meta_path = Path.join(assets_dir, "snapshot-meta.json")
    history_archive_path = Path.join(assets_dir, "history.tar.gz")
    history_meta_path = Path.join(assets_dir, "history-meta.json")

    File.write!(snapshot_path, ~s({"snapshot_id":"abc"}))
    File.write!(snapshot_meta_path, ~s({"snapshot_id":"abc"}))
    File.write!(history_archive_path, "archive")
    File.write!(history_meta_path, ~s({"to_snapshot_id":"abc"}))

    {snapshot_path, snapshot_meta_path, history_archive_path, history_meta_path}
  end

  defp gh_script(log_path) do
    """
    #!/bin/sh
    set -eu
    printf '%s\\n' "$*" >> "#{log_path}"

    if [ "$1" = "release" ] && [ "$2" = "create" ]; then
      echo "https://github.com/agentjido/llmdb/releases/tag/$3"
      exit 0
    fi

    echo "unexpected command: $*" >&2
    exit 1
    """
  end

  defp tmp_dir(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
