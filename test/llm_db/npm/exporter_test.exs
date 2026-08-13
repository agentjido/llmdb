defmodule LLMDB.NPM.ExporterTest do
  use ExUnit.Case, async: true

  alias LLMDB.NPM.Exporter
  alias LLMDB.Snapshot

  test "exports provider shards that retain canonical snapshot identity" do
    output_dir =
      Path.join(
        System.tmp_dir!(),
        "llm-db-npm-exporter-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(output_dir) end)

    manifest = Exporter.export!(output_dir)
    openai = output_dir |> Path.join("providers/openai.json") |> File.read!() |> Jason.decode!()

    assert manifest["snapshot_id"] ==
             "priv/llm_db/snapshot.json"
             |> File.read!()
             |> Jason.decode!()
             |> Map.fetch!("snapshot_id")

    assert manifest["provider_count"] == map_size(manifest["providers"])
    assert manifest["model_count"] > 1_000
    assert manifest["providers"]["openai"]["model_count"] == map_size(openai["models"])
    assert openai["id"] == "openai"
    assert openai["models"]["gpt-5.4"]["provider"] == "openai"
  end

  test "rejects unsafe output directories" do
    assert_raise ArgumentError, fn -> Exporter.export!(Path.expand(".")) end
  end

  test "does not replace a populated directory that it does not own" do
    output_dir =
      Path.join(
        System.tmp_dir!(),
        "llm-db-npm-exporter-unowned-#{System.unique_integer([:positive])}"
      )

    important_path = Path.join(output_dir, "important.txt")
    File.mkdir_p!(output_dir)
    File.write!(important_path, "keep")
    on_exit(fn -> File.rm_rf!(output_dir) end)

    assert_raise ArgumentError, ~r/without an ownership marker/, fn ->
      Exporter.export!(output_dir)
    end

    assert File.read!(important_path) == "keep"
  end

  test "exports a snapshot-valid provider ID that contains a hyphen" do
    test_dir = tmp_dir("hyphen")
    source_path = Path.join(test_dir, "snapshot.json")
    output_dir = Path.join(test_dir, "export")
    on_exit(fn -> File.rm_rf!(test_dir) end)

    write_single_provider_snapshot!(source_path, "foo-bar")

    manifest = Exporter.export!(output_dir, source: source_path)

    assert manifest["provider_count"] == 1
    assert manifest["providers"]["foo-bar"]["id"] == "foo-bar"
    assert File.regular?(Path.join(output_dir, "providers/foo-bar.json"))
  end

  test "rejects provider IDs that are not safe on cross-platform NPM installs" do
    test_dir = tmp_dir("unsafe_provider")
    source_path = Path.join(test_dir, "snapshot.json")
    output_dir = Path.join(test_dir, "export")
    on_exit(fn -> File.rm_rf!(test_dir) end)

    write_single_provider_snapshot!(source_path, "foo:bar")

    assert_raise RuntimeError, ~r/not safe for a cross-platform NPM subpath/, fn ->
      Exporter.export!(output_dir, source: source_path)
    end
  end

  test "keeps the prior export when a staged export fails" do
    test_dir = tmp_dir("staged_failure")
    source_path = Path.join(test_dir, "snapshot.json")
    output_dir = Path.join(test_dir, "export")
    on_exit(fn -> File.rm_rf!(test_dir) end)

    Exporter.export!(output_dir)
    prior_manifest = File.read!(Path.join(output_dir, "manifest.json"))

    write_single_provider_snapshot!(source_path, "foo_bar", &Map.delete(&1, "generated_at"))

    assert_raise KeyError, fn ->
      Exporter.export!(output_dir, source: source_path)
    end

    assert File.read!(Path.join(output_dir, "manifest.json")) == prior_manifest
    assert Path.wildcard(Path.join(test_dir, ".export.staging-*")) == []
  end

  defp write_single_provider_snapshot!(path, provider_id, transform \\ &Function.identity/1) do
    snapshot =
      "priv/llm_db/snapshot.json"
      |> File.read!()
      |> Jason.decode!()

    provider =
      snapshot
      |> get_in(["providers", "openai"])
      |> Map.put("id", provider_id)
      |> Map.update!("models", fn models ->
        Map.new(models, fn {model_id, model} ->
          {model_id, Map.put(model, "provider", provider_id)}
        end)
      end)

    snapshot =
      snapshot
      |> Map.put("providers", %{provider_id => provider})
      |> transform.()
      |> then(&Map.put(&1, "snapshot_id", Snapshot.snapshot_id(&1)))

    Snapshot.write!(path, snapshot)
  end

  defp tmp_dir(name) do
    Path.join(
      System.tmp_dir!(),
      "llm-db-npm-exporter-#{name}-#{System.unique_integer([:positive])}"
    )
  end
end
