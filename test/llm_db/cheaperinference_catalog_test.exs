defmodule LLMDB.CheaperInferenceCatalogTest do
  use ExUnit.Case, async: false

  setup do
    {:ok, _snapshot} = LLMDB.load()
    :ok
  end

  test "packages the provider runtime contract" do
    assert {:ok, provider} = LLMDB.provider(:cheaperinference)
    refute provider.catalog_only
    assert provider.name == "Cheaper Inference"
    assert provider.runtime.base_url == "https://api.cheaperinference.com/v1"
    assert provider.runtime.auth.type == "bearer"
    assert provider.runtime.auth.env == ["CHEAPERINFERENCE_API_KEY"]
  end

  test "packages the documented starter models" do
    expected = %{
      "gpt-5.4-mini" => %{
        context: 400_000,
        output: 128_000,
        input: 0.4875,
        output_cost: 2.925,
        cache_read: 0.04875
      },
      "claude-sonnet-5" => %{
        context: 1_000_000,
        output: 128_000,
        input: 1.337238,
        output_cost: 6.686191,
        cache_read: 0.133724
      }
    }

    for {id, metadata} <- expected do
      assert {:ok, model} = LLMDB.model({:cheaperinference, id})
      refute model.catalog_only
      assert model.provider_model_id == id
      assert model.limits == %{context: metadata.context, output: metadata.output}
      assert model.cost.input == metadata.input
      assert model.cost.output == metadata.output_cost
      assert model.cost.cache_read == metadata.cache_read
      assert model.modalities == %{input: [:text, :image], output: [:text]}
      assert model.capabilities.reasoning.enabled
      assert model.capabilities.streaming.text
      pricing = model.extra["pricing"]
      assert pricing["dynamic"]
      assert pricing["price_basis"] == "current_market_rate"
      assert pricing["sources_checked_at"] == "2026-10-26"
      assert length(pricing["source_urls"]) == 2

      for operation <- [:text, :object] do
        execution = model.execution[operation]
        assert execution.supported
        assert execution.family == "openai_chat_compatible"
        assert execution.wire_protocol == "openai_chat"
        assert execution.path == "/chat/completions"
      end
    end
  end

  test "adds the provider to the packaged registry" do
    provider = LLMDB.Packaged.snapshot()["providers"]["cheaperinference"]
    assert is_map(provider)
    assert Map.keys(provider["models"]) == ["claude-sonnet-5", "gpt-5.4-mini"]
    assert {:ok, :cheaperinference} = LLMDB.Generated.ProviderRegistry.fetch("cheaperinference")
  end
end
