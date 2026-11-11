defmodule LLMDB.AnthropicFableMetadataTest do
  use ExUnit.Case, async: true

  alias LLMDB.{ExecutionContract, Model, Normalize, Pricing, Provider}
  alias LLMDB.Sources.Local

  @local_dir "priv/llm_db/local"
  @model_id "claude-fable-5-1"
  @fable_5_2 "claude-fable-5-2"

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

    assert components["token.cache_write"].applies_when == %{cache_ttl: "5m"}
    assert components["token.cache_write.1h"].derives_from == "token.input"
    assert components["token.cache_write.1h"].multiplier == 2.0
    assert components["pricing.batch"].multiplier == 0.5
    assert components["pricing.batch"].applies_to == ["token.*"]
  end

  test "Claude Fable 5.2 metadata matches Anthropic documentation" do
    model = fable_model(@fable_5_2)

    assert model.provider_model_id == @fable_5_2
    assert model.name == "Claude Fable 5.2"
    assert model.family == "claude-fable-5"
    assert model.aliases == []
    assert model.release_date == "2026-11-09"
    assert model.lifecycle.status == "active"
    assert model.knowledge == "2026-06"
    assert model.doc_url == "https://platform.claude.com/docs/en/models/fable-5-2/overview"

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
    assert model.capabilities.reasoning.thinking.default_type == "adaptive"
    assert model.capabilities.reasoning.thinking.disable_supported == false
    assert model.capabilities.reasoning.thinking.raw_output_supported == false
    assert model.capabilities.reasoning.thinking.summary_supported == true

    assert model.capabilities.tools.enabled == true
    assert model.capabilities.tools.strict == true
    assert model.capabilities.tools.forced_choice == false
    assert model.capabilities.json.schema == true
    assert model.capabilities.batch.supported == true

    assert model.extra.training_data_cutoff == "2026-06"
    assert model.extra.retirement_not_before == "2027-11-09"
    assert model.extra.comparative_latency == "moderate"
    assert model.extra.data_retention_requirement == "30_days"
    assert model.extra.fallback_models == ["claude-opus-4-8", "claude-opus-5"]
    assert model.extra.platform_model_ids.claude_api == @fable_5_2
    assert model.extra.platform_model_ids.amazon_bedrock == "anthropic.claude-fable-5-2"
    assert model.extra.fast_mode_model_ids.microsoft_foundry == "claude-fable-5-2-fast"
    assert model.extra.pricing.sources_checked_at == "2026-11-10"

    assert "https://platform.claude.com/docs/en/models/fable-5-2/whats-new-fable-5-2" in model.extra.source_urls
  end

  test "Claude Fable 5.2 is executable before the Models API cache lists it" do
    provider = anthropic_provider()
    model = fable_model(@fable_5_2)
    enriched = ExecutionContract.enrich_model(model, ExecutionContract.enrich_provider(provider))

    refute enriched.catalog_only
    assert enriched.execution.text.family == "anthropic_messages"
    assert enriched.execution.object.family == "anthropic_messages"
  end

  test "Claude Fable 5.2 selects published standard, cache, batch, fast, and residency rates" do
    [model] = fable_model(@fable_5_2) |> List.wrap() |> Pricing.apply_cost_components()
    components = Map.new(model.pricing.components, &{&1.id, &1})

    assert components["token.input"].rate == 8.0
    assert components["token.output"].rate == 40.0
    assert components["token.cache_read"].rate == 0.2
    assert components["token.cache_write"].rate == 10.0
    assert components["token.cache_write"].applies_when == %{cache_ttl: "5m"}
    assert components["token.cache_write.1h"].derives_from == "token.input"
    assert components["token.cache_write.1h"].multiplier == 2.0
    assert components["pricing.batch"].multiplier == 0.5
    assert components["pricing.fast"].multiplier == 2.0
    assert components["pricing.data_residency"].multiplier == 1.1

    # Published per-MTok rates: input, output, cache read, cache write.
    for {context, expected} <- [
          {[cache_ttl: "5m"], [8.0, 40.0, 0.2, 10.0]},
          {[cache_ttl: "1h"], [8.0, 40.0, 0.2, 16.0]},
          {[cache_ttl: "5m", api: "batch"], [4.0, 20.0, 0.1, 5.0]},
          {[cache_ttl: "5m", request_body: %{speed: "fast"}], [16.0, 80.0, 0.4, 20.0]},
          {[cache_ttl: "5m", inference_geo: "us"], [8.8, 44.0, 0.22, 11.0]}
        ] do
      selection = Pricing.components_for(model, pricing_context(context))
      assert selection.unresolved == []
      assert effective_rates(selection) |> rounded() == expected
    end

    batch =
      Pricing.components_for(
        model,
        pricing_context(api: "batch", request_body: %{speed: "fast"})
      )

    refute Enum.any?(batch.components ++ batch.unresolved, &(&1.id == "pricing.fast"))
  end

  defp pricing_context(overrides) do
    Keyword.merge(
      [
        api: "messages",
        request_body: %{speed: "standard"},
        inference_geo: "global",
        cache_ttl: "5m",
        input_tokens: 1_000
      ],
      overrides
    )
  end

  defp effective_rates(selection) do
    tokens = Enum.filter(selection.components, &(&1.kind == "token"))
    by_id = Map.new(tokens, &{&1.id, &1})

    modifier =
      selection.components
      |> Enum.filter(&(&1.kind == "other"))
      |> Enum.reduce(1.0, &(&1.multiplier * &2))

    for meter <- ~w(input_tokens output_tokens cache_read_tokens cache_write_tokens) do
      component = Enum.find(tokens, &(&1.meter == meter))

      base =
        if component[:derives_from],
          do: by_id[component.derives_from].rate * component.multiplier,
          else: component.rate

      base * modifier
    end
  end

  defp rounded(rates), do: Enum.map(rates, &Float.round(&1 * 1.0, 6))

  defp anthropic_provider do
    {:ok, data} = Local.load(%{dir: @local_dir})

    data
    |> Map.fetch!("anthropic")
    |> Map.delete(:models)
    |> Map.put(:id, :anthropic)
    |> Provider.new!()
  end

  defp fable_model(model_id \\ @model_id) do
    {:ok, data} = Local.load(%{dir: @local_dir})

    data
    |> Map.fetch!("anthropic")
    |> Map.fetch!(:models)
    |> Normalize.normalize_models()
    |> Enum.map(&Model.new!/1)
    |> Enum.find(&(&1.id == model_id))
  end
end
