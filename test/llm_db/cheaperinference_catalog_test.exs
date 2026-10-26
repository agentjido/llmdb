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
      "gpt-5.4-mini" => %{context: 400_000, output: 128_000, input: 0.49, output_cost: 2.92},
      "claude-sonnet-5" => %{
        context: 1_000_000,
        output: 64_000,
        input: 1.34,
        output_cost: 6.69
      }
    }

    for {id, metadata} <- expected do
      assert {:ok, model} = LLMDB.model({:cheaperinference, id})
      refute model.catalog_only
      assert model.provider_model_id == id
      assert model.limits == %{context: metadata.context, output: metadata.output}
      assert model.cost.input == metadata.input
      assert model.cost.output == metadata.output_cost
      assert model.capabilities.reasoning.enabled
      assert model.capabilities.streaming.text
      assert model.extra["pricing_dynamic"]
      assert model.extra["pricing_checked_at"] == "2026-10-26"

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
