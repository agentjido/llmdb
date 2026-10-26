defmodule LLMDB.InferenceCatalogTest do
  use ExUnit.Case, async: false

  alias LLMDB.Packaged
  alias LLMDB.Sources.InferenceNet

  setup do
    {:ok, _catalog} = LLMDB.load()
    :ok
  end

  test "packages the current Inference.net endpoint and bearer authentication" do
    assert {:ok, provider} = LLMDB.provider(:inference)
    refute provider.catalog_only
    assert provider.base_url == "https://api.inference.net/v1"
    assert provider.runtime.base_url == "https://api.inference.net/v1"
    assert provider.runtime.auth.type == "bearer"
    assert provider.runtime.auth.env == ["INFERENCE_API_KEY"]
  end

  test "retains every cached public model and removes stale models.dev entries" do
    {:ok, source} = InferenceNet.load(%{})
    models = Packaged.snapshot()["providers"]["inference"]["models"]

    assert source["inference"].models != []
    assert Enum.sort(Map.keys(models)) == Enum.sort(Enum.map(source["inference"].models, & &1.id))
    refute Map.has_key?(models, "google/gemma-3")
    refute Map.has_key?(models, "meta/llama-3.1-8b-instruct")
  end

  test "loads current models as executable OpenAI-compatible chat models" do
    assert {:ok, model} = LLMDB.model("inference:deepseek-v4.1-flash-1017")
    refute model.catalog_only
    assert model.limits == %{context: 1_040_000, output: 393_216}
    assert model.cost == %{input: 0.3, output: 1.0, cache_read: 0.007}
    assert model.capabilities.reasoning.effort.values == ~w(none low high max)
    assert model.capabilities.tools.enabled
    assert model.capabilities.json.strict

    for operation <- [:text, :object] do
      contract = model.execution[operation]
      assert contract.supported
      assert contract.family == "openai_chat_compatible"
      assert contract.wire_protocol == "openai_chat"
      assert contract.path == "/chat/completions"
    end
  end

  test "keeps documented tool exceptions executable without tool claims" do
    for id <- ["llama-3.2-1b-instruct", "inference-net/schematron-v2-small"] do
      assert {:ok, model} = LLMDB.model({:inference, id})
      refute model.catalog_only
      refute model.capabilities.tools.enabled
      refute model.capabilities.streaming.tool_calls
      assert model.capabilities.json.schema
      assert model.execution.text.supported
    end
  end
end
