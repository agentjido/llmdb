defmodule LLMDB.MetaMetadataTest do
  use ExUnit.Case, async: true

  alias LLMDB.{ExecutionContract, Model, Normalize, Pricing, Provider}
  alias LLMDB.Sources.Local

  test "the packaged catalog resolves Meta Muse Wonder" do
    assert {:ok, provider} = LLMDB.provider(:meta)
    assert provider.env == ["META_API_KEY"]
    assert provider.runtime.auth.env == ["META_API_KEY"]
    assert {:ok, model} = LLMDB.model(:meta, "muse-wonder-1.0")
    refute model.catalog_only
    assert model.execution.text.path == "/responses"
    assert model.cost.input == 4.0
    assert model.limits.context == 1_048_576
    refute Map.has_key?(model.limits, :output)
  end

  test "Muse Wonder resolves from reviewed local metadata without a registry cache" do
    {:ok, local} = Local.load(%{dir: "priv/llm_db/local"})
    meta = local["meta"]
    provider = meta |> Map.delete(:models) |> Map.put(:id, :meta) |> Provider.new!()
    [attrs] = Normalize.normalize_models(meta.models)
    model = Model.new!(attrs)
    model = ExecutionContract.enrich_model(model, ExecutionContract.enrich_provider(provider))

    assert provider.runtime.auth.type == "bearer"
    assert provider.runtime.auth.env == ["META_API_KEY"]
    assert provider.base_url == "https://api.meta.ai/v1"
    assert model.id == "muse-wonder-1.0"
    assert model.limits.context == 1_048_576
    refute Map.has_key?(model.limits, :output)
    assert model.modalities.input == [:text, :image, :video, :audio, :pdf]
    assert model.modalities.output == [:text]
    assert model.capabilities.reasoning.enabled
    assert model.capabilities.reasoning.effort.values == ~w(minimal low medium high xhigh max)
    refute Map.has_key?(model.capabilities.reasoning.effort, :default)
    refute model.capabilities.reasoning.thinking.disable_supported
    assert model.capabilities.tools.parallel
    assert model.capabilities.tools.streaming
    assert model.capabilities.json.strict
    refute model.catalog_only
    assert model.execution.text.family == "openai_responses_compatible"
    assert model.extra.availability == "preview"
    assert model.extra.pricing_mode == "standard"
    refute model.extra.pricing.contributor_mode

    [model] = Pricing.apply_cost_components([model])
    assert {:ok, selection} = Pricing.select_components(model)
    assert Enum.find(selection.components, &(&1.id == "token.input")).rate == 4.0
    assert Enum.find(selection.components, &(&1.id == "token.cache_read")).rate == 0.2
    assert Enum.find(selection.components, &(&1.id == "token.output")).rate == 20.0
    assert Enum.find(selection.components, &(&1.id == "tool.web_search")).rate == 2.5
  end
end
