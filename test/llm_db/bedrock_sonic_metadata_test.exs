defmodule LLMDB.BedrockSonicMetadataTest do
  use ExUnit.Case, async: true

  alias LLMDB.{Catalog, Loader, Model}
  alias LLMDB.Snapshot.Builder

  @tag :tmp_dir
  test "the retired Nova Sonic resolves to a distinct active successor", %{tmp_dir: tmp_dir} do
    assert {:ok, artifact} = Builder.build(output_dir: tmp_dir)
    %{snapshot_path: path} = Builder.write!(artifact)
    assert {:ok, catalog} = Loader.load(snapshot_source: {:file, path})

    assert {:ok, {:amazon_bedrock, "amazon.nova-sonic-v1:0", original}} =
             Catalog.resolve_model(catalog, :amazon_bedrock, "amazon.nova-sonic-v1:0")

    assert original.id == "amazon.nova-sonic-v1:0"
    assert Model.retired?(original)

    assert original.lifecycle == %{
             status: "retired",
             deprecated_at: "2026-03-13",
             retires_at: "2026-09-14",
             replacement: "amazon.nova-2-sonic-v1:0"
           }

    assert {:ok, {:amazon_bedrock, "amazon.nova-2-sonic-v1:0", successor}} =
             Catalog.resolve_model(catalog, :amazon_bedrock, original.lifecycle.replacement)

    assert successor.id == original.lifecycle.replacement
    assert Model.effective_status(successor) == "active"
    assert successor.modalities == %{input: [:audio, :text], output: [:audio, :text]}
    assert successor.extra["bedrock"]["operation"] == "InvokeModelWithBidirectionalStream"

    for model <- [original, successor] do
      assert model.catalog_only
      refute model.capabilities.chat
    end
  end
end
