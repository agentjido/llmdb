defmodule LLMDB.MiniMaxConditionalPricingTest do
  use ExUnit.Case, async: true

  alias LLMDB.{Model, Normalize, Pricing}
  alias LLMDB.Sources.Local

  setup_all do
    {:ok, data} = Local.load(%{dir: "priv/llm_db/local"})

    model =
      data["minimax"].models
      |> Normalize.normalize_models()
      |> Enum.find(&(&1.id == "MiniMax-M3"))
      |> Model.new!()

    %{model: model}
  end

  test "provider context bands select one current full-request rate per meter", %{model: model} do
    for {tier, expected} <- [
          {"lte_512k", [0.3, 1.2, 0.06]},
          {"gt_512k", [0.6, 2.4, 0.12]}
        ] do
      selection =
        Pricing.components_for(model, context_tier: tier, service_tier: "standard")

      assert selection.unresolved == []
      assert length(selection.components) == 3
      assert Enum.all?(selection.components, &(&1.charge_scope == "full_request"))
      assert_rates(selection, expected)
    end

    assert model.cost == %{input: 0.3, output: 1.2, cache_read: 0.06}
  end

  test "Priority increases every token meter once and does not reapply the permanent discount",
       %{model: model} do
    for {tier, expected} <- [
          {"lte_512k", [0.45, 1.8, 0.09]},
          {"gt_512k", [0.9, 3.6, 0.18]}
        ] do
      selection =
        Pricing.components_for(model, context_tier: tier, service_tier: "priority")

      assert selection.unresolved == []
      assert length(selection.components) == 4
      assert_rates(selection, expected)
    end
  end

  test "numeric input cannot silently invent a decimal or binary 512k tariff boundary",
       %{model: model} do
    for tokens <- [1_000, 512_000, 512_001, 524_288, 524_289, 900_000] do
      selection =
        Pricing.components_for(model, input_tokens: tokens, service_tier: "standard")

      assert selection.components == []
      assert length(selection.unresolved) == 6
    end

    assert model.extra.pricing.boundary_provider_value == "512k"
    assert model.extra.pricing.boundary_numeric_status == "unknown"
  end

  test "thinking controls do not change the confirmed tariff", %{model: model} do
    for tier <- ["lte_512k", "gt_512k"] do
      context = [context_tier: tier, service_tier: "standard"]

      assert Pricing.components_for(model, context ++ [thinking: true]) ==
               Pricing.components_for(model, context ++ [thinking: false])
    end
  end

  test "cost enrichment retains tariff conditions and never introduces a flat fallback",
       %{model: model} do
    [enriched] = Pricing.apply_cost_components([model])

    assert Enum.sort_by(enriched.pricing.components, & &1.id) ==
             Enum.sort_by(model.pricing.components, & &1.id)

    assert Pricing.apply_cost_components([enriched]) == [enriched]

    assert Pricing.components_for(enriched, input_tokens: 900_000, service_tier: "standard").components ==
             []
  end

  # Checks these curated tariffs; billing arithmetic belongs to the consumer.
  defp assert_rates(selection, expected) do
    tokens = Enum.filter(selection.components, &(&1.kind == "token"))
    meters = ~w(input_tokens output_tokens cache_read_tokens)
    assert Enum.sort(Enum.map(tokens, & &1.meter)) == Enum.sort(meters)

    multiplier =
      selection.components
      |> Enum.filter(&(&1.kind == "other"))
      |> Enum.reduce(1.0, fn modifier, acc ->
        assert modifier.applies_to == ["token.*"]
        acc * modifier.multiplier
      end)

    for {meter, rate} <- Enum.zip(meters, expected) do
      component = Enum.find(tokens, &(&1.meter == meter))
      assert component.per == 1_000_000
      assert_in_delta component.rate * multiplier, rate, 1.0e-9
    end
  end
end
