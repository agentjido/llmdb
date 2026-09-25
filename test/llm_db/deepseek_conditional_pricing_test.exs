defmodule LLMDB.DeepSeekConditionalPricingTest do
  use ExUnit.Case, async: true

  alias LLMDB.{Loader, Model, Normalize, Pricing}
  alias LLMDB.Sources.Local

  @flash_ids ~w(deepseek-flash deepseek-v4-flash deepseek-v4-flash-vision-exp)
  @ids @flash_ids ++ ["deepseek-v4-pro"]
  @meters ~w(input_tokens output_tokens cache_read_tokens)

  setup_all do
    {:ok, data} = Local.load(%{dir: "priv/llm_db/local"})

    models =
      data["deepseek"].models
      |> Normalize.normalize_models()
      |> Enum.filter(&(&1.id in @ids))
      |> Enum.map(&Model.new!/1)
      |> Pricing.apply_cost_components()
      |> Map.new(&{&1.id, &1})

    %{models: models}
  end

  test "each known period selects exactly one rate per charged token category", ctx do
    for id <- @ids, {period, factor} <- [{"off_peak", 1}, {"peak", 2}] do
      selection = Pricing.components_for(ctx.models[id], pricing_period: period)
      assert selection.unresolved == []
      assert Enum.sort(Enum.map(selection.components, & &1.meter)) == Enum.sort(@meters)

      for {meter, rate} <- Enum.zip(@meters, expected_rates(id)) do
        component = Enum.find(selection.components, &(&1.meter == meter))
        assert component.rate == rate * factor
        assert component.per == 1_000_000
        assert component.mode == "standard"
        assert component.charge_scope == "full_request"
        assert component.source == "provider_docs"
      end
    end
  end

  test "missing or unknown periods never silently select the cheaper summary", ctx do
    for model <- Map.values(ctx.models), context <- [%{}, %{pricing_period: nil}] do
      assert %{components: [], unresolved: unresolved} = Pricing.components_for(model, context)
      assert length(unresolved) == 6
    end

    for model <- Map.values(ctx.models) do
      assert Pricing.components_for(model, pricing_period: "unconfirmed") == %{
               components: [],
               unresolved: []
             }
    end
  end

  test "request timestamps and a weekday alone do not resolve provider billing time", ctx do
    for model <- Map.values(ctx.models) do
      selection =
        Pricing.components_for(model,
          timestamp: "2026-09-22T02:00:00Z",
          created: 1_790_042_400,
          weekday: 2,
          chinese_public_holiday: false
        )

      assert selection.components == []
      assert length(selection.unresolved) == 6
    end
  end

  test "the current price matrix does not introduce a context-length surcharge", ctx do
    for model <- Map.values(ctx.models), period <- ~w(off_peak peak) do
      assert Pricing.components_for(model, pricing_period: period, input_tokens: 1_000) ==
               Pricing.components_for(model, pricing_period: period, input_tokens: 900_000)
    end
  end

  test "cached input and reasoning subsets are counted once", ctx do
    # A million prompt tokens contains 750K hits and 250K misses. The 100K
    # completion tokens already include the 70K reasoning-token breakdown.
    usage = %{input_tokens: 250_000, cache_read_tokens: 750_000, output_tokens: 100_000}

    for id <- @ids,
        {period, factor} <- [{"off_peak", 1}, {"peak", 2}] do
      selection =
        Pricing.components_for(ctx.models[id],
          pricing_period: period,
          reasoning_tokens: 70_000,
          input_tokens: 1_000_000
        )

      assert length(selection.components) == 3
      refute Enum.any?(selection.components, &(&1.id == "token.reasoning"))

      cost =
        Enum.reduce(selection.components, 0.0, fn component, acc ->
          count = Map.fetch!(usage, String.to_existing_atom(component.meter))
          acc + count / component.per * component.rate
        end)

      expected = if id == "deepseek-v4-pro", do: 0.3795, else: 0.09975
      assert_in_delta cost, expected * factor, 1.0e-9
    end
  end

  test "legacy summaries and repeated loading cannot restore duplicate reasoning charges", ctx do
    for model <- Map.values(ctx.models) do
      [input, output, cached] = expected_rates(model.id)
      assert model.cost.input == input
      assert model.cost.output == output
      assert model.cost.cache_read == cached
      assert model.cost.reasoning == output
      assert model.pricing.currency == "USD"
      assert length(model.pricing.components) == 6
      assert Pricing.apply_cost_components([model]) == [model]
    end
  end

  test "compatibility IDs share Flash tariffs while Pro keeps its own model and rates", ctx do
    for id <- @flash_ids do
      model = ctx.models[id]
      assert model.extra.pricing.canonical_model_id == "deepseek-flash"
      assert model.extra.pricing.served_model == "DeepSeek-V4.1-Flash"
      assert model.pricing.components == ctx.models["deepseek-flash"].pricing.components
    end

    pro = ctx.models["deepseek-v4-pro"]
    assert pro.extra.pricing.canonical_model_id == "deepseek-v4-pro"
    assert pro.extra.pricing.served_model == "DeepSeek-V4-Pro-0813"
    refute pro.pricing.components == ctx.models["deepseek-flash"].pricing.components
  end

  test "pricing evidence does not assert an unpublished period schedule", ctx do
    for model <- Map.values(ctx.models) do
      pricing = model.extra.pricing
      assert pricing.sources_checked_at == "2026-09-22"
      assert pricing.output_includes_reasoning
      assert pricing.price_basis == "off_peak"
      refute Map.has_key?(pricing, :period_schedule)
    end
  end

  test "packaged loading preserves every tariff and never regenerates a reasoning charge", ctx do
    assert {:ok, loaded} =
             Loader.load(allow: %{deepseek: @ids}, deny: %{}, prefer: [], custom: %{})

    assert length(loaded.models.deepseek) == 4

    for model <- loaded.models.deepseek do
      expected = ctx.models[model.id]
      assert model.pricing.excluded_cost_components == ["token.reasoning"]
      assert length(model.pricing.components) == 6

      assert json_components(model.pricing.components) ==
               json_components(expected.pricing.components)

      assert Pricing.apply_cost_components([model]) == [model]

      assert %{components: [], unresolved: unresolved} = Pricing.components_for(model)
      assert length(unresolved) == 6
    end
  end

  defp expected_rates("deepseek-v4-pro"), do: [0.66, 1.98, 0.022]
  defp expected_rates(_flash_id), do: [0.15, 0.6, 0.003]

  defp json_components(components) do
    components |> Enum.sort_by(& &1.id) |> Jason.encode!() |> Jason.decode!()
  end
end
