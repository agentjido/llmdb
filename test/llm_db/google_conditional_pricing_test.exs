defmodule LLMDB.GoogleConditionalPricingTest do
  use ExUnit.Case, async: true

  alias LLMDB.{Model, Normalize, Pricing}
  alias LLMDB.Sources.Local

  @models ~w(gemini-3.1-pro-preview gemini-3.1-pro-preview-customtools)

  setup_all do
    {:ok, data} = Local.load(%{dir: "priv/llm_db/local"})

    models =
      data["google"].models
      |> Normalize.normalize_models()
      |> Enum.filter(&(&1.id in @models))
      |> Enum.map(&Model.new!/1)

    assert length(models) == length(@models)
    %{models: models}
  end

  test "the 200K prompt boundary selects one full-request price for each token meter", ctx do
    for model <- ctx.models,
        {tokens, rates} <- [{200_000, [2.0, 12.0, 0.2]}, {200_001, [4.0, 18.0, 0.4]}] do
      selection = Pricing.components_for(model, context(input_tokens: tokens))
      assert selection.unresolved == []
      assert length(selection.components) == 3
      assert Enum.all?(selection.components, &(&1.charge_scope == "full_request"))
      assert_rates(selection, rates)
      assert model.cost == %{input: 2.0, output: 12.0, cache_read: 0.2}
    end
  end

  test "Batch and Flex discounts exclude cached reads at both context tiers", ctx do
    for model <- ctx.models,
        {tokens, rates} <- [{200_000, [1.0, 6.0, 0.2]}, {200_001, [2.0, 9.0, 0.4]}],
        overrides <- [[api: "batch"], [service_tier: "flex"]] do
      selection =
        Pricing.components_for(model, context([input_tokens: tokens] ++ overrides))

      assert selection.unresolved == []
      assert_rates(selection, rates)
    end
  end

  test "Priority increases every token meter and explicit storage without stacking with Batch",
       ctx do
    for model <- ctx.models,
        {tokens, rates} <- [{200_000, [3.6, 21.6, 0.36]}, {200_001, [7.2, 32.4, 0.72]}] do
      selection =
        Pricing.components_for(
          model,
          context(input_tokens: tokens, service_tier: "priority", cache_type: "explicit")
        )

      assert selection.unresolved == []
      assert_rates(selection, rates)
      storage = Enum.find(selection.components, &(&1.id == "storage.cache"))
      assert storage.meter == "cache_storage_token_hours"
      assert_in_delta effective_rate(storage, selection), 8.1, 1.0e-9

      batch =
        Pricing.components_for(
          model,
          context(api: "batch", service_tier: "priority", cache_type: "explicit")
        )

      assert batch.unresolved == []
      refute Enum.any?(batch.components, &(&1.id == "pricing.priority"))
      assert_rates(batch, [1.0, 6.0, 0.2])
      assert effective_rate(storage, batch) == 4.5
    end
  end

  test "cache reads do not reduce the total prompt used for tier selection", ctx do
    for model <- ctx.models do
      selection =
        Pricing.components_for(
          model,
          context(input_tokens: 200_001, cache_read_tokens: 199_000, output_tokens: 1)
        )

      assert_rates(selection, [4.0, 18.0, 0.4])

      selection =
        Pricing.components_for(
          model,
          context(input_tokens: 200_000, output_tokens: 60_000)
        )

      assert_rates(selection, [2.0, 12.0, 0.2])
    end
  end

  test "unknown prompt size preserves both possible tiers as unresolved", ctx do
    for model <- ctx.models do
      selection = Pricing.components_for(model, context(input_tokens: nil))
      assert selection.components == []
      assert length(selection.unresolved) == 6

      [enriched] = Pricing.apply_cost_components([model])

      assert Enum.sort_by(enriched.pricing.components, & &1.id) ==
               Enum.sort_by(model.pricing.components, & &1.id)

      assert Pricing.apply_cost_components([enriched]) == [enriched]
    end
  end

  defp context(overrides) do
    Keyword.merge(
      [
        api: "generate_content",
        service_tier: "standard",
        input_tokens: 1_000,
        cache_type: "implicit"
      ],
      overrides
    )
  end

  defp assert_rates(selection, expected) do
    tokens = Enum.filter(selection.components, &(&1.kind == "token"))
    meters = ~w(input_tokens output_tokens cache_read_tokens)
    assert Enum.sort(Enum.map(tokens, & &1.meter)) == Enum.sort(meters)

    for {meter, rate} <- Enum.zip(meters, expected) do
      component = Enum.find(tokens, &(&1.meter == meter))
      assert component.per == 1_000_000
      assert_in_delta effective_rate(component, selection), rate, 1.0e-9
    end
  end

  # Consumer arithmetic for the curated exact IDs and token wildcard above.
  defp effective_rate(component, selection) do
    selection.components
    |> Enum.filter(fn modifier ->
      modifier.kind == "other" and
        (component.id in modifier.applies_to or
           (component.kind == "token" and "token.*" in modifier.applies_to))
    end)
    |> Enum.reduce(component.rate, &(&1.multiplier * &2))
  end
end
