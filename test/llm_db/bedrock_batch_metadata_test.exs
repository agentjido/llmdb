defmodule LLMDB.BedrockBatchMetadataTest do
  use ExUnit.Case, async: true

  alias LLMDB.{Model, Normalize}
  alias LLMDB.Sources.Local

  test "Nova Lite and Nova Pro declare batch inference support" do
    assert {:ok, data} = Local.load(%{dir: "priv/llm_db/local"})

    models =
      data["amazon_bedrock"].models
      |> Normalize.normalize_models()
      |> Map.new(&{&1.id, Model.new!(&1)})

    for id <- ~w(amazon.nova-lite-v1:0 amazon.nova-pro-v1:0) do
      assert %Model{capabilities: %{batch: %{supported: true}}} = Map.fetch!(models, id)
    end
  end
end
