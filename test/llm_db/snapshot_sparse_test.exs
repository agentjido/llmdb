defmodule LLMDB.SnapshotSparseTest do
  use ExUnit.Case, async: true

  alias LLMDB.{Loader, Snapshot, Snapshot.Builder}

  defmodule FixtureSource do
    @behaviour LLMDB.Source

    @impl LLMDB.Source
    def load(_opts) do
      {:ok,
       %{
         "test_provider_alpha" => %{
           id: :test_provider_alpha,
           name: "Test Provider Alpha",
           models: [%{id: "sparse-model", provider: :test_provider_alpha}]
         }
       }}
    end
  end

  @fixture_dir Path.expand("../fixtures/snapshots", __DIR__)
  @v1_path Path.join(@fixture_dir, "catalog-v1.json")
  @v2_path Path.join(@fixture_dir, "catalog-sparse-v2.json")
  @unknown_provider_key "golden_unknown_provider_91cc"
  @unknown_model_key "golden_unknown_model_7f41"

  test "v1 and sparse v2 fixtures produce identical public catalog values" do
    assert {:ok, v1_catalog} = load_catalog(@v1_path)
    assert {:ok, v2_catalog} = load_catalog(@v2_path)

    assert v1_catalog.providers_by_id == v2_catalog.providers_by_id
    assert v1_catalog.models_by_key == v2_catalog.models_by_key
    assert v1_catalog.aliases_by_key == v2_catalog.aliases_by_key
  end

  test "v1 remains byte-stable while sparse v2 expands schema defaults" do
    v1_content = File.read!(@v1_path)
    v2_content = File.read!(@v2_path)

    assert {:ok, v1} = Snapshot.decode(v1_content)
    assert {:ok, v2} = Snapshot.decode(v2_content)

    assert v1["schema_version"] == Snapshot.schema_version()
    assert v2["schema_version"] == Snapshot.sparse_schema_version()
    assert Snapshot.encode(v1) == String.trim_trailing(v1_content)
    assert Snapshot.encode(v2) == String.trim_trailing(v2_content)
    assert Snapshot.verify(v1) == :ok
    assert Snapshot.verify(v2) == :ok

    provider = v2["providers"]["test_provider_alpha"]
    default_model = provider["models"]["default-model"]

    assert Map.has_key?(provider, "name")
    assert provider["name"] == nil
    assert provider["catalog_only"] == false
    assert default_model["aliases"] == []
    assert default_model["deprecated"] == false
    assert default_model["retired"] == false
    assert default_model["catalog_only"] == false
    assert default_model["capabilities"] == nil
  end

  test "sparse encoding is deterministic and matches the golden wire fixture" do
    {:ok, v1} = Snapshot.read(@v1_path)
    expected_wire = @v2_path |> File.read!() |> Jason.decode!()

    sparse = Snapshot.to_sparse(v1)

    assert sparse == expected_wire
    assert Snapshot.to_sparse(v1) == sparse
    assert Snapshot.encode(sparse) == Snapshot.encode(expected_wire)
  end

  test "explicit nulls and unknown data survive sparse round trips without atom creation" do
    assert_not_existing_atom(@unknown_provider_key)
    assert_not_existing_atom(@unknown_model_key)

    wire = @v2_path |> File.read!() |> Jason.decode!()
    provider_wire = wire["providers"]["test_provider_alpha"]
    model_wire = provider_wire["models"]["default-model"]

    assert Map.has_key?(provider_wire, "exclude_models")
    assert provider_wire["exclude_models"] == nil
    assert provider_wire["future_provider_field"] == false
    assert provider_wire["extra"][@unknown_provider_key] == nil
    assert model_wire["future_wire_field"] == %{"enabled" => false, "value" => nil}
    assert model_wire["extra"][@unknown_model_key] == nil

    assert {:ok, decoded} = Snapshot.decode(Snapshot.encode(wire))
    provider = decoded["providers"]["test_provider_alpha"]
    model = provider["models"]["default-model"]

    assert provider["exclude_models"] == nil
    assert provider["future_provider_field"] == false
    assert provider["extra"][@unknown_provider_key] == nil
    assert model["future_wire_field"] == %{"enabled" => false, "value" => nil}
    assert model["extra"][@unknown_model_key] == nil
    assert Snapshot.encode(decoded) == Snapshot.encode(wire)
    assert_not_existing_atom(@unknown_provider_key)
    assert_not_existing_atom(@unknown_model_key)
  end

  test "builder emits v2 only through the opt-in side-by-side path" do
    output_dir =
      Path.join(
        System.tmp_dir!(),
        "llm-db-sparse-builder-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(output_dir) end)

    assert {:ok, artifact} =
             Builder.build(
               sources: [{FixtureSource, %{}}],
               schema_version: Snapshot.sparse_schema_version(),
               output_dir: output_dir
             )

    assert artifact.schema_version == Snapshot.sparse_schema_version()
    assert artifact.snapshot["schema_version"] == Snapshot.sparse_schema_version()
    assert artifact.metadata["snapshot_schema_version"] == Snapshot.sparse_schema_version()

    artifact = Builder.write!(artifact)
    assert {:ok, decoded} = Snapshot.read(artifact.snapshot_path)
    assert decoded["schema_version"] == Snapshot.sparse_schema_version()

    assert_raise ArgumentError, ~r/cannot replace the packaged v1 snapshot/, fn ->
      Builder.write!(artifact, install_source: true)
    end
  end

  test "build task rejects installing sparse v2 as the packaged default" do
    assert_raise Mix.Error, ~r/cannot be installed as the packaged default/, fn ->
      Mix.Tasks.LlmDb.Build.run(["--schema-version", "2", "--install-source"])
    end
  end

  defp load_catalog(path) do
    Loader.load(
      snapshot_source: {:file, path},
      allow: :all,
      deny: %{},
      prefer: [],
      custom: %{}
    )
  end

  defp assert_not_existing_atom(value) do
    assert_raise ArgumentError, fn -> String.to_existing_atom(value) end
  end
end
