defmodule LLMDB.ZAICodingPlanPricingTest do
  use ExUnit.Case, async: true

  alias LLMDB.{Model, Normalize, Pricing}
  alias LLMDB.Sources.Local

  @rates %{
    "glm-5.3" => %{"input_tokens" => 6.9, "cache_read_tokens" => 1.7, "output_tokens" => 24.0},
    "glm-5.3-flash" => %{
      "input_tokens" => 2.3,
      "cache_read_tokens" => 0.56,
      "output_tokens" => 8.0
    }
  }
  @cost_ids ~w(token.input token.output token.cache_read token.cache_write token.reasoning)
  @legacy_cost %{input: 0, output: 0, cache_read: 0, cache_write: 0, reasoning: 0}

  setup_all do
    {:ok, data} = Local.load(%{dir: "priv/llm_db/local"})

    models =
      data["zai_coding_plan"].models
      |> Normalize.normalize_models()
      |> Enum.filter(&Map.has_key?(@rates, &1.id))
      |> Enum.map(&Model.new!(Map.put(&1, :cost, @legacy_cost)))
      |> Pricing.apply_cost_components()
      |> Map.new(&{&1.id, &1})

    %{models: models}
  end

  test "current plan consumes credits at exclusive peak or off-peak token rates", ctx do
    for {id, expected} <- @rates,
        {period, multiplier} <- [{"peak", 1.0}, {"off_peak", 0.5}] do
      model = ctx.models[id]
      assert model.provider == :zai_coding_plan
      assert model.pricing.currency == "credits"
      selection = Pricing.components_for(model, context(pricing_period: period))
      assert selection.unresolved == []
      assert length(selection.components) == 3

      for component <- selection.components do
        assert component.kind == "token"
        assert component.unit == "token"
        assert component.per == 10_000
        assert component.mode == period
        assert component.source == "provider_docs"
        assert_in_delta component.rate, expected[component.meter] * multiplier, 1.0e-10
      end
    end
  end

  test "missing product, plan generation or period never implies free or peak pricing", ctx do
    for model <- Map.values(ctx.models),
        key <- [:billing_product, :plan_generation, :pricing_period],
        missing <- [:omitted, nil] do
      request =
        if missing == :omitted,
          do: Keyword.delete(context(), key),
          else: Keyword.put(context(), key, nil)

      selection = Pricing.components_for(model, request)
      assert selection.components == []
      assert selection.unresolved != []
    end

    for model <- Map.values(ctx.models) do
      selection = Pricing.components_for(model)
      assert selection.components == []
      assert length(selection.unresolved) == 6
    end
  end

  test "USD API calls and legacy plan generations do not match credit tariffs", ctx do
    for model <- Map.values(ctx.models),
        overrides <- [
          [billing_product: "pay_as_you_go_api"],
          [plan_generation: "legacy_plan_v1"],
          [plan_generation: "legacy_plan_v2"],
          [plan_generation: "legacy_team_plan"]
        ] do
      assert Pricing.components_for(model, context(overrides)) == %{
               components: [],
               unresolved: []
             }
    end
  end

  test "legacy zero summaries cannot inject unqualified token prices into credits", ctx do
    for model <- Map.values(ctx.models) do
      assert model.cost == @legacy_cost
      assert Enum.sort(model.pricing.excluded_cost_components) == Enum.sort(@cost_ids)
      assert length(model.pricing.components) == 6
      assert Enum.all?(model.pricing.components, &(&1.rate > 0))
      refute Enum.any?(model.pricing.components, &(&1.meter == "cache_write_tokens"))
      assert Pricing.apply_cost_components([model]) == [model]
    end
  end

  test "calendar metadata distinguishes ordinary periods from quota-only promotions", ctx do
    for model <- Map.values(ctx.models) do
      schedule = model.extra.pricing.period_schedule
      assert schedule.context_key == "pricing_period"
      assert schedule.timezone == "Asia/Singapore"
      assert schedule.utc_offset == "+08:00"
      assert schedule.weekday_numbering == "iso8601"
      assert schedule.peak_weekdays == [1, 2, 3, 4, 5]
      assert schedule.peak_windows == [%{start: "14:00", end: "18:00"}]
      assert schedule.off_peak_weekdays == [6, 7]
      assert schedule.other_hours_period == "off_peak"
      assert schedule.instant_boundary_semantics == "not_published"
      assert schedule.billing_timestamp_status == "not_published"

      [override] = model.extra.pricing.period_overrides
      assert override.plan_type == "individual"
      assert override.published_start_date == "2026-09-25"
      assert override.published_end_date == "2026-10-07"
      assert override.pricing_period == "off_peak"
    end

    flagship = ctx.models["glm-5.3"]
    refute Map.has_key?(flagship.extra.pricing, :quota_campaigns)
    [campaign] = ctx.models["glm-5.3-flash"].extra.pricing.quota_campaigns
    assert campaign.paid_plan_required
    assert campaign.start_time == "23:00"
    assert campaign.end_time_next_day == "09:00"
    assert campaign.zcode_minimum_version == "3.10"
  end

  defp context(overrides \\ []) do
    Keyword.merge(
      [billing_product: "coding_plan", plan_generation: "token_credits", pricing_period: "peak"],
      overrides
    )
  end
end
