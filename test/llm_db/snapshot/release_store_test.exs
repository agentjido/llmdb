defmodule LLMDB.Snapshot.ReleaseStoreTest do
  use ExUnit.Case, async: false

  alias LLMDB.Snapshot.ReleaseStore

  test "creates snapshot, catalog, and history releases atomically with unique tags" do
    tmp_dir = tmp_dir("release_store_create")
    bin_dir = Path.join(tmp_dir, "bin")
    assets_dir = Path.join(tmp_dir, "assets")
    log_path = Path.join(tmp_dir, "gh.log")
    script_path = Path.join(bin_dir, "gh")
    original_path = System.get_env("PATH")

    {snapshot_path, snapshot_meta_path, history_archive_path, history_meta_path} =
      write_assets!(assets_dir)

    {snapshot_index_path, latest_path} = write_catalog_assets!(assets_dir)

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

    assert {:ok, catalog_tag} =
             ReleaseStore.publish_snapshot_index([snapshot_index_path, latest_path])

    assert catalog_tag =~ ~r/^catalog-index-\d+-\d+$/

    assert {:ok, history_tag} =
             ReleaseStore.publish_history_release(
               [history_archive_path, history_meta_path],
               "abc",
               history_entries: []
             )

    assert history_tag =~ ~r/^history-latest-\d+-\d+-abc$/

    log = File.read!(log_path)
    assert log =~ "release create #{snapshot_tag} #{snapshot_path} #{snapshot_meta_path}"
    assert log =~ "release create #{catalog_tag}"
    assert log =~ "snapshot-index-"
    assert log =~ "latest-"
    assert log =~ "release create #{history_tag}"
    assert log =~ "history-meta-"
    assert log =~ ".tar.gz"
    refute log =~ "release upload"
    refute log =~ "delete-asset"
    refute log =~ "--clobber"
  end

  test "reuses an indexed snapshot and publishes a new history generation" do
    tmp_dir = tmp_dir("release_store_reuse")
    bin_dir = Path.join(tmp_dir, "bin")
    assets_dir = Path.join(tmp_dir, "assets")
    log_path = Path.join(tmp_dir, "gh.log")
    script_path = Path.join(bin_dir, "gh")
    original_path = System.get_env("PATH")

    {snapshot_path, snapshot_meta_path, history_archive_path, history_meta_path} =
      write_assets!(assets_dir)

    File.mkdir_p!(bin_dir)
    File.write!(script_path, gh_script(log_path, "history-latest"))
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

    assert {:ok, history_tag} =
             ReleaseStore.publish_history_release(
               [history_archive_path, history_meta_path],
               "abc",
               history_entries: [existing_history_entry]
             )

    assert history_tag =~ ~r/^history-latest-\d+-\d+-abc$/

    log = File.read!(log_path)
    assert log =~ "release create #{history_tag}"
    assert log =~ "history-meta-"
    assert log =~ ".tar.gz"
    refute log =~ "--clobber"
    refute log =~ "release upload"
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

  test "loads more than one thousand snapshots from one compact index asset" do
    snapshots =
      Enum.map(1..1_001, fn index ->
        %{
          "snapshot_id" => "snapshot-#{index}",
          "snapshot_url" => "https://example.test/snapshot-#{index}.json"
        }
      end)

    test_pid = self()

    plug = fn conn ->
      send(test_pid, {:request, conn.request_path})

      case conn.request_path do
        "/repos/agentjido/llmdb/releases" ->
          Req.Test.json(conn, [])

        "/repos/agentjido/llmdb/releases/tags/catalog-index" ->
          Req.Test.json(conn, versioned_release("catalog-index", "0001"))

        "/catalog/snapshot-index-0001.json" ->
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          |> Plug.Conn.send_resp(
            200,
            Jason.encode!(%{"schema_version" => 1, "snapshots" => snapshots})
          )
      end
    end

    assert {:ok, loaded} = ReleaseStore.fetch_snapshot_index(req_opts: [plug: plug])
    assert length(loaded) == 1_001
    assert List.last(loaded)["snapshot_id"] == "snapshot-1001"

    assert_receive {:request, "/repos/agentjido/llmdb/releases"}
    assert_receive {:request, "/repos/agentjido/llmdb/releases/tags/catalog-index"}
    assert_receive {:request, "/catalog/snapshot-index-0001.json"}

    refute_receive {:request, _path}
  end

  test "fetches the compact index once and the latest snapshot once" do
    snapshot = valid_snapshot()
    snapshot_id = snapshot["snapshot_id"]
    test_pid = self()

    plug = fn conn ->
      send(test_pid, {:request, conn.request_path})

      case conn.request_path do
        "/repos/agentjido/llmdb/releases" ->
          Req.Test.json(conn, [versioned_release("catalog-index-0001", "0001")])

        "/catalog/snapshot-index-0001.json" ->
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          |> Plug.Conn.send_resp(
            200,
            Jason.encode!(%{
              "schema_version" => 1,
              "snapshots" => [
                %{
                  "snapshot_id" => snapshot_id,
                  "snapshot_url" => "https://example.test/snapshot.json"
                }
              ]
            })
          )

        "/snapshot.json" ->
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          |> Plug.Conn.send_resp(200, Jason.encode!(snapshot))
      end
    end

    cache_dir = tmp_dir("release_store_fetch")

    assert {:ok, %{snapshot_id: ^snapshot_id}} =
             ReleaseStore.fetch_snapshot(:latest, cache_dir: cache_dir, req_opts: [plug: plug])

    assert_receive {:request, "/repos/agentjido/llmdb/releases"}
    assert_receive {:request, "/catalog/snapshot-index-0001.json"}

    assert_receive {:request, "/snapshot.json"}
    refute_receive {:request, _path}
  end

  test "selects the latest complete catalog generation release" do
    test_pid = self()

    plug = fn conn ->
      send(test_pid, {:request, conn.request_path})

      case conn.request_path do
        "/repos/agentjido/llmdb/releases" ->
          draft_release =
            versioned_release("catalog-index-0003", "0003")
            |> Map.put("published_at", "2026-08-24T03:00:00Z")
            |> Map.put("draft", true)

          incomplete_release = %{
            "tag_name" => "catalog-index-0002",
            "published_at" => "2026-08-24T02:00:00Z",
            "assets" => [
              %{
                "name" => "snapshot-index-0002.json",
                "browser_download_url" => "https://example.test/catalog/snapshot-index-0002.json"
              }
            ]
          }

          complete_release =
            versioned_release("catalog-index-0001", "0001")
            |> Map.put("published_at", "2026-08-24T01:00:00Z")

          Req.Test.json(conn, [draft_release, incomplete_release, complete_release])

        "/catalog/snapshot-index-0001.json" ->
          Req.Test.json(conn, %{"schema_version" => 1, "snapshots" => []})
      end
    end

    assert {:ok, []} = ReleaseStore.fetch_snapshot_index(req_opts: [plug: plug])
    assert_receive {:request, "/repos/agentjido/llmdb/releases"}
    assert_receive {:request, "/catalog/snapshot-index-0001.json"}
    refute_receive {:request, "/catalog/snapshot-index-0002.json"}
    refute_receive {:request, "/catalog/snapshot-index-0003.json"}
  end

  test "fetches history from the latest immutable checkpoint generation" do
    test_pid = self()

    plug = fn conn ->
      send(test_pid, {:request, conn.request_path})

      case conn.request_path do
        "/repos/agentjido/llmdb/releases" ->
          Req.Test.json(conn, [history_versioned_release("history-latest-0001", "0001")])

        "/history/history-meta-0001.json" ->
          Req.Test.json(conn, %{"to_snapshot_id" => "abc"})
      end
    end

    assert {:ok, %{"to_snapshot_id" => "abc"}} =
             ReleaseStore.fetch_history_meta(req_opts: [plug: plug])

    assert_receive {:request, "/repos/agentjido/llmdb/releases"}
    assert_receive {:request, "/history/history-meta-0001.json"}
    refute_receive {:request, _path}
  end

  test "keeps the fixed history checkpoint release readable during migration" do
    test_pid = self()

    plug = fn conn ->
      send(test_pid, {:request, conn.request_path})

      case conn.request_path do
        "/repos/agentjido/llmdb/releases" ->
          Req.Test.json(conn, [])

        "/repos/agentjido/llmdb/releases/tags/history-latest" ->
          Req.Test.json(conn, history_versioned_release("history-latest", "0001"))

        "/history/history-meta-0001.json" ->
          Req.Test.json(conn, %{"to_snapshot_id" => "legacy"})
      end
    end

    assert {:ok, %{"to_snapshot_id" => "legacy"}} =
             ReleaseStore.fetch_history_meta(req_opts: [plug: plug])

    assert_receive {:request, "/repos/agentjido/llmdb/releases"}
    assert_receive {:request, "/repos/agentjido/llmdb/releases/tags/history-latest"}
    assert_receive {:request, "/history/history-meta-0001.json"}
    refute_receive {:request, _path}
  end

  test "returns the GitHub error without changing an earlier generation" do
    tmp_dir = tmp_dir("release_store_upload_failure")
    bin_dir = Path.join(tmp_dir, "bin")
    assets_dir = Path.join(tmp_dir, "assets")
    log_path = Path.join(tmp_dir, "gh.log")
    script_path = Path.join(bin_dir, "gh")
    original_path = System.get_env("PATH")

    {_snapshot_path, _snapshot_meta_path, history_archive_path, history_meta_path} =
      write_assets!(assets_dir)

    File.mkdir_p!(bin_dir)
    File.write!(script_path, gh_script(log_path, nil, fail_create: true))
    File.chmod!(script_path, 0o755)
    File.write!(log_path, "")
    System.put_env("PATH", "#{bin_dir}:#{original_path}")

    on_exit(fn -> System.put_env("PATH", original_path) end)

    assert {:error, "create failed"} =
             ReleaseStore.publish_history_release(
               [history_archive_path, history_meta_path],
               "abc"
             )

    log = File.read!(log_path)
    assert log =~ "release create history-latest-"
    refute log =~ "--clobber"
    refute log =~ "release upload"
    refute log =~ "delete-asset"
  end

  test "retries with a replacement generation after GitHub returns immutable release 422" do
    tmp_dir = tmp_dir("release_store_retention")
    bin_dir = Path.join(tmp_dir, "bin")
    assets_dir = Path.join(tmp_dir, "assets")
    log_path = Path.join(tmp_dir, "gh.log")
    script_path = Path.join(bin_dir, "gh")
    original_path = System.get_env("PATH")

    {snapshot_index_path, latest_path} = write_catalog_assets!(assets_dir)

    File.mkdir_p!(bin_dir)
    File.write!(script_path, gh_script(log_path, nil, immutable_create_once: true))
    File.chmod!(script_path, 0o755)
    File.write!(log_path, "")
    System.put_env("PATH", "#{bin_dir}:#{original_path}")

    on_exit(fn -> System.put_env("PATH", original_path) end)

    assert {:ok, replacement_tag} =
             ReleaseStore.publish_snapshot_index([snapshot_index_path, latest_path])

    create_commands =
      log_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, "release create catalog-index-"))

    assert length(create_commands) == 2
    [failed_command, replacement_command] = create_commands
    refute failed_command == replacement_command
    assert replacement_command =~ "release create #{replacement_tag}"
    refute replacement_command =~ "release upload catalog-index"
    refute replacement_command =~ "delete-asset"
  end

  test "retains two complete immutable generation releases" do
    tmp_dir = tmp_dir("release_store_retention")
    bin_dir = Path.join(tmp_dir, "bin")
    assets_dir = Path.join(tmp_dir, "assets")
    log_path = Path.join(tmp_dir, "gh.log")
    script_path = Path.join(bin_dir, "gh")
    original_path = System.get_env("PATH")

    {_snapshot_path, _snapshot_meta_path, history_archive_path, history_meta_path} =
      write_assets!(assets_dir)

    release_tags = ["history-latest-0002", "history-latest-0001"]

    File.mkdir_p!(bin_dir)
    File.write!(script_path, gh_script(log_path, nil, release_tags: release_tags))
    File.chmod!(script_path, 0o755)
    File.write!(log_path, "")
    System.put_env("PATH", "#{bin_dir}:#{original_path}")

    on_exit(fn -> System.put_env("PATH", original_path) end)

    assert {:ok, history_tag} =
             ReleaseStore.publish_history_release(
               [history_archive_path, history_meta_path],
               "abc"
             )

    log = File.read!(log_path)
    assert log =~ "release create #{history_tag}"
    assert log =~ "release delete history-latest-0001"
    refute log =~ "release delete history-latest-0002"
    refute log =~ "delete-asset"
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

  defp write_catalog_assets!(assets_dir) do
    File.mkdir_p!(assets_dir)

    snapshot_index_path = Path.join(assets_dir, "snapshot-index.json")
    latest_path = Path.join(assets_dir, "latest.json")

    File.write!(snapshot_index_path, ~s({"schema_version":1,"snapshots":[]}))
    File.write!(latest_path, ~s({"snapshot_id":"abc"}))

    {snapshot_index_path, latest_path}
  end

  defp gh_script(log_path, existing_tag \\ nil, opts \\ []) do
    fail_create? = Keyword.get(opts, :fail_create, false)
    immutable_create_once? = Keyword.get(opts, :immutable_create_once, false)
    immutable_marker = "#{log_path}.immutable-release"

    release_list =
      opts
      |> Keyword.get(:release_tags, [])
      |> Enum.map(&%{"tagName" => &1, "isDraft" => false})
      |> Jason.encode!()

    """
    #!/bin/sh
    set -eu
    printf '%s\\n' "$*" >> "#{log_path}"

    if [ "$1" = "release" ] && [ "$2" = "view" ] && [ "$3" = "#{existing_tag}" ]; then
      exit 0
    fi

    if [ "$1" = "release" ] && [ "$2" = "list" ]; then
      printf '%s\\n' '#{release_list}'
      exit 0
    fi

    if [ "$1" = "release" ] && [ "$2" = "create" ]; then
      if [ "#{immutable_create_once?}" = "true" ] && [ ! -e "#{immutable_marker}" ]; then
        : > "#{immutable_marker}"
        echo "HTTP 422: Cannot upload assets to an immutable release." >&2
        exit 1
      fi
      if [ "#{fail_create?}" = "true" ]; then
        echo "create failed" >&2
        exit 1
      fi
      echo "https://github.com/agentjido/llmdb/releases/tag/$3"
      exit 0
    fi

    if [ "$1" = "release" ] && [ "$2" = "upload" ]; then
      echo "HTTP 422: Cannot upload assets to an immutable release." >&2
      exit 1
    fi

    if [ "$1" = "release" ] && [ "$2" = "delete" ]; then
      exit 0
    fi

    echo "unexpected command: $*" >&2
    exit 1
    """
  end

  defp versioned_release(tag, generation) do
    %{
      "tag_name" => tag,
      "assets" => [
        %{
          "name" => "snapshot-index-#{generation}.json",
          "browser_download_url" =>
            "https://example.test/catalog/snapshot-index-#{generation}.json"
        },
        %{
          "name" => "latest-#{generation}.json",
          "browser_download_url" => "https://example.test/catalog/latest-#{generation}.json"
        }
      ]
    }
  end

  defp history_versioned_release(tag, generation) do
    %{
      "tag_name" => tag,
      "assets" => [
        %{
          "name" => "history-#{generation}.tar.gz",
          "browser_download_url" => "https://example.test/history/history-#{generation}.tar.gz"
        },
        %{
          "name" => "history-meta-#{generation}.json",
          "browser_download_url" => "https://example.test/history/history-meta-#{generation}.json"
        }
      ]
    }
  end

  defp valid_snapshot do
    snapshot = %{
      "schema_version" => 1,
      "version" => 2,
      "generated_at" => "2026-08-17T00:00:00Z",
      "providers" => %{}
    }

    Map.put(snapshot, "snapshot_id", LLMDB.Snapshot.snapshot_id(snapshot))
  end

  defp tmp_dir(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
