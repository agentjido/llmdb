defmodule LLMDB.History.RebuilderTest do
  use ExUnit.Case, async: false

  alias LLMDB.{History, History.Rebuilder, Snapshot}

  setup do
    previous_history_dir = Application.get_env(:llm_db, :history_dir)

    on_exit(fn ->
      clear_history_cache()

      if previous_history_dir == nil do
        Application.delete_env(:llm_db, :history_dir)
      else
        Application.put_env(:llm_db, :history_dir, previous_history_dir)
      end
    end)

    :ok
  end

  test "rebuilds snapshot-based history that preserves lineage timelines" do
    history_dir = temp_dir("llm_db_history_rebuilder")
    snapshots_dir = temp_dir("llm_db_snapshot_rebuilder")

    snapshot_a =
      snapshot(%{
        "openai" => %{
          "id" => "openai",
          "models" => %{
            "gpt-4o" => %{
              "id" => "gpt-4o",
              "provider" => "openai",
              "aliases" => ["gpt-4o-latest"]
            }
          }
        }
      })

    snapshot_b =
      snapshot(%{
        "openai" => %{
          "id" => "openai",
          "models" => %{
            "gpt-4.1" => %{
              "id" => "gpt-4.1",
              "provider" => "openai",
              "aliases" => ["gpt-4o", "gpt-4o-latest"]
            }
          }
        }
      })

    write_snapshot(snapshots_dir, snapshot_a)
    write_snapshot(snapshots_dir, snapshot_b)

    observations = [
      %{
        "snapshot_id" => snapshot_a["snapshot_id"],
        "captured_at" => "2026-01-01T00:00:00Z"
      },
      %{
        "snapshot_id" => snapshot_b["snapshot_id"],
        "captured_at" => "2026-01-02T00:00:00Z",
        "parent_snapshot_id" => snapshot_a["snapshot_id"]
      }
    ]

    assert {:ok, summary} =
             Rebuilder.rebuild(
               observations: observations,
               output_dir: history_dir,
               source: "test",
               snapshot_loader: fn snapshot_id ->
                 Snapshot.read(
                   Path.join([snapshots_dir, snapshot_id, Snapshot.snapshot_filename()])
                 )
               end
             )

    assert summary.from_snapshot_id == snapshot_a["snapshot_id"]
    assert summary.to_snapshot_id == snapshot_b["snapshot_id"]
    assert summary.snapshots_written == 2
    assert summary.events_written == 3
    assert summary.mode == :full
    assert summary.snapshots_processed == 2
    assert File.exists?(Path.join(history_dir, Snapshot.history_state_filename()))

    Application.put_env(:llm_db, :history_dir, history_dir)
    clear_history_cache()

    assert {:ok, timeline} = History.timeline(:openai, "gpt-4.1")
    assert Enum.map(timeline, & &1["type"]) == ["introduced", "introduced", "removed"]

    assert Enum.map(timeline, & &1["lineage_key"]) == [
             "openai:gpt-4o",
             "openai:gpt-4o",
             "openai:gpt-4o"
           ]
  end

  test "incremental rebuild loads only new snapshots and matches a full rebuild" do
    history_dir = temp_dir("llm_db_history_incremental")
    full_dir = temp_dir("llm_db_history_full")

    snapshot_a = model_snapshot("gpt-test", "First")
    snapshot_b = model_snapshot("gpt-test", "Second")
    snapshot_c = model_snapshot("gpt-test", "Third")

    observations = [
      observation(snapshot_a, "2026-01-01T00:00:00Z"),
      observation(snapshot_b, "2026-01-02T00:00:00Z"),
      observation(snapshot_c, "2026-01-03T00:00:00Z")
    ]

    snapshots =
      Map.new([snapshot_a, snapshot_b, snapshot_c], fn snapshot ->
        {snapshot["snapshot_id"], snapshot}
      end)

    assert {:ok, initial_summary} =
             Rebuilder.rebuild(
               observations: Enum.take(observations, 2),
               output_dir: history_dir,
               source: "test",
               snapshot_loader: &Map.fetch(snapshots, &1)
             )

    assert initial_summary.mode == :full

    test_pid = self()

    assert {:ok, incremental_summary} =
             Rebuilder.rebuild(
               observations: observations,
               output_dir: history_dir,
               source: "test",
               snapshot_loader: fn snapshot_id ->
                 send(test_pid, {:loaded, snapshot_id})
                 Map.fetch(snapshots, snapshot_id)
               end
             )

    assert incremental_summary.mode == :incremental
    assert incremental_summary.snapshots_processed == 1
    assert incremental_summary.events_added == 1
    snapshot_c_id = snapshot_c["snapshot_id"]
    assert_receive {:loaded, ^snapshot_c_id}
    refute_receive {:loaded, _snapshot_id}

    assert {:ok, full_summary} =
             Rebuilder.rebuild(
               observations: observations,
               output_dir: full_dir,
               source: "test",
               mode: :full,
               snapshot_loader: &Map.fetch(snapshots, &1)
             )

    assert full_summary.events_written == incremental_summary.events_written

    for path <- [
          "snapshots.ndjson",
          "events/2026.ndjson",
          Snapshot.snapshot_index_filename(),
          Snapshot.latest_filename(),
          Snapshot.history_state_filename()
        ] do
      assert File.read!(Path.join(history_dir, path)) == File.read!(Path.join(full_dir, path))
    end
  end

  test "missing checkpoint state uses the full migration path" do
    history_dir = temp_dir("llm_db_history_missing_state")
    snapshot = model_snapshot("gpt-test", "First")
    observations = [observation(snapshot, "2026-01-01T00:00:00Z")]

    assert {:ok, _summary} =
             Rebuilder.rebuild(
               observations: observations,
               output_dir: history_dir,
               snapshot_loader: fn _snapshot_id -> {:ok, snapshot} end
             )

    File.rm!(Path.join(history_dir, Snapshot.history_state_filename()))
    test_pid = self()

    assert {:ok, summary} =
             Rebuilder.rebuild(
               observations: observations,
               output_dir: history_dir,
               snapshot_loader: fn snapshot_id ->
                 send(test_pid, {:loaded, snapshot_id})
                 {:ok, snapshot}
               end
             )

    assert summary.mode == :full
    assert summary.snapshots_processed == 1
    assert_receive {:loaded, _snapshot_id}
  end

  defp snapshot(providers) do
    document = %{
      "schema_version" => Snapshot.schema_version(),
      "version" => 2,
      "generated_at" => "2026-01-01T00:00:00Z",
      "providers" => providers
    }

    Map.put(document, "snapshot_id", Snapshot.snapshot_id(document))
  end

  defp model_snapshot(model_id, name) do
    snapshot(%{
      "openai" => %{
        "id" => "openai",
        "models" => %{
          model_id => %{
            "id" => model_id,
            "provider" => "openai",
            "name" => name
          }
        }
      }
    })
  end

  defp observation(snapshot, captured_at) do
    %{
      "snapshot_id" => snapshot["snapshot_id"],
      "captured_at" => captured_at
    }
  end

  defp write_snapshot(base_dir, snapshot) do
    path = Path.join([base_dir, snapshot["snapshot_id"], Snapshot.snapshot_filename()])
    Snapshot.write!(path, snapshot)
  end

  defp temp_dir(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end

  defp clear_history_cache, do: History.clear_cache()
end
