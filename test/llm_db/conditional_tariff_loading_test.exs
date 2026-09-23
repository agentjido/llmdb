defmodule LLMDB.ConditionalTariffLoadingTest do
  use ExUnit.Case, async: true

  alias LLMDB.{Loader, Pricing}

  setup_all do
    {:ok, loaded} =
      Loader.load(
        allow: %{
          minimax: ["MiniMax-M3"],
          zai: ["glm-5.3", "glm-5.3-flash"],
          zai_coding_plan: ["glm-5.3", "glm-5.3-flash"]
        },
        deny: %{},
        prefer: [],
        custom: %{}
      )

    %{models: loaded.models_by_key}
  end

  test "packaged MiniMax bands remain conditional after legacy cost conversion", ctx do
    model = ctx.models[{:minimax, "MiniMax-M3"}]
    assert model.pricing.currency == "USD"

    for {tier, rates} <- [
          {"lte_512k", [0.3, 1.2, 0.06]},
          {"gt_512k", [0.6, 2.4, 0.12]}
        ] do
      selection = Pricing.components_for(model, context_tier: tier, service_tier: "standard")
      assert selection.unresolved == []
      assert length(selection.components) == 3

      assert Map.new(selection.components, &{&1.meter, &1.rate}) ==
               Map.new(Enum.zip(~w(input_tokens output_tokens cache_read_tokens), rates))
    end

    unknown = Pricing.components_for(model, input_tokens: 900_000, service_tier: "standard")
    assert unknown.components == []
    assert length(unknown.unresolved) == 6
    [again] = Pricing.apply_cost_components([model])
    assert again == model
  end

  test "the same GLM model ID keeps direct dollars separate from subscription credits", ctx do
    for {id, input_rate} <- [{"glm-5.3", 6.9}, {"glm-5.3-flash", 2.3}] do
      plan = ctx.models[{:zai_coding_plan, id}]
      direct = ctx.models[{:zai, id}]
      assert direct.pricing.currency == "USD"
      assert plan.pricing.currency == "credits"
      assert plan.cost.input == 0
      assert length(plan.pricing.excluded_cost_components) == 5

      for {period, factor} <- [{"peak", 1.0}, {"off_peak", 0.5}] do
        context = [
          billing_product: "coding_plan",
          plan_generation: "token_credits",
          pricing_period: period
        ]

        selection = Pricing.components_for(plan, context)
        assert selection.unresolved == []
        assert length(selection.components) == 3
        assert Enum.all?(selection.components, &(&1.per == 10_000 and &1.rate > 0))
        input = Enum.find(selection.components, &(&1.meter == "input_tokens"))
        assert_in_delta input.rate, input_rate * factor, 1.0e-9
      end

      assert Pricing.components_for(direct, pricing_period: "peak") ==
               Pricing.components_for(direct, pricing_period: "off_peak")

      assert Pricing.components_for(plan).components == []
      assert length(Pricing.components_for(plan).unresolved) == 6
      assert Pricing.apply_cost_components([plan]) == [plan]
    end
  end
end
