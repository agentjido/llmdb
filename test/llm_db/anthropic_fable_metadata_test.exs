defmodule LLMDB.AnthropicFableMetadataTest do
  use ExUnit.Case, async: true

  alias LLMDB.{Model, Normalize, Pricing}
  alias LLMDB.Sources.Local

  @local_dir "priv/llm_db/local"
  @model_id "claude-fable-5-1"

  test "Claude Fable 5.1 metadata matches Anthropic documentation" do
    model = fable_model()

    assert model.provider_model_id == @model_id
    assert model.name == "Claude Fable 5.1"
    assert model.aliases == []
    assert model.release_date == "2026-09-01"
    assert model.lifecycle.status == "active"
    assert model.knowledge == "2026-06"
    assert model.doc_url == "https://platform.claude.com/docs/en/models/fable-5-1/overview"

    assert model.limits.context == 1_000_000
    assert model.limits.input == 1_000_000
    assert model.limits.output == 128_000
    assert model.modalities.input == [:text, :image]
    assert model.modalities.output == [:text]

    assert model.capabilities.reasoning.enabled == true
    assert model.capabilities.reasoning.effort.supported == true
    assert model.capabilities.reasoning.effort.values == ~w[low medium high xhigh max]
    assert model.capabilities.reasoning.effort.default == "high"
    assert model.capabilities.reasoning.thinking.types == ["adaptive"]
    assert model.capabilities.reasoning.thinking.disable_supported == false
    assert model.capabilities.reasoning.thinking.raw_output_supported == false
    assert model.capabilities.reasoning.thinking.summary_supported == true
    assert model.capabilities.reasoning.thinking.encrypted_supported == true

    assert model.capabilities.tools.enabled == true
    assert model.capabilities.tools.streaming == true
    assert model.capabilities.tools.strict == true
    assert model.capabilities.tools.parallel == true
    assert model.capabilities.tools.forced_choice == false
    assert model.capabilities.json.schema == true
    assert model.capabilities.json.strict == true
    assert model.capabilities.batch.supported == true
    assert model.capabilities.citations.supported == true
    assert model.capabilities.code_execution.supported == true
    assert model.capabilities.context_management.supported == true

    assert model.capabilities.context_management.features ==
             ~w[clear_thinking clear_tool_uses compact]

    assert model.extra.training_data_cutoff == "2026-06"
    assert model.extra.retirement_not_before == "2027-09-01"
    assert model.extra.platform_model_ids.amazon_bedrock == "anthropic.claude-fable-5-1"

    assert "https://platform.claude.com/docs/en/about-claude/models/model-ids-and-versions" in model.extra.source_urls
  end

  test "Claude Fable 5.1 pricing includes standard, cache, and batch rates" do
    [model] = fable_model() |> List.wrap() |> Pricing.apply_cost_components()
    components = Map.new(model.pricing.components, &{&1.id, &1})

    assert components["token.input"].rate == 10.0
    assert components["token.output"].rate == 50.0
    assert components["token.cache_read"].rate == 0.25
    assert components["token.cache_write"].rate == 12.5

    assert components["token.cache_write"].applies_when == %{
             cache_operation: "write",
             cache_ttl: "5m"
           }

    assert components["token.cache_write.1h"].rate == 20.0
    assert components["token.input.batch"].rate == 5.0
    assert components["token.output.batch"].rate == 25.0
  end

  defp fable_model do
    {:ok, data} = Local.load(%{dir: @local_dir})

    data
    |> Map.fetch!("anthropic")
    |> Map.fetch!(:models)
    |> Normalize.normalize_models()
    |> Enum.map(&Model.new!/1)
    |> Enum.find(&(&1.id == @model_id))
  end
end
