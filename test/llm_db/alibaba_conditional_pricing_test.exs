defmodule LLMDB.AlibabaConditionalPricingTest do
  use ExUnit.Case, async: true

  alias LLMDB.{Model, Normalize, Pricing}
  alias LLMDB.Sources.Local

  @tiers %{
    "qwen3.7-plus" => {256_000, 1_000_000, [0.4, 1.6, 0.04, 0.5], [1.2, 4.8, 0.12, 1.5]},
    "qwen3.6-plus" => {256_000, 1_000_000, [0.5, 3.0, 0.05, 0.625], [2.0, 6.0, 0.2, 2.5]},
    "qwen3.6-max-preview" => {128_000, 256_000, [1.3, 7.8, 0.13, 1.625], [2.0, 12.0, 0.2, 2.5]}
  }
  @meters ~w(input_tokens output_tokens cache_read_tokens cache_write_tokens)

  setup_all do
    {:ok, data} = Local.load(%{dir: "priv/llm_db/local"})

    models =
      data["alibaba"].models
      |> Normalize.normalize_models()
      |> Enum.filter(&Map.has_key?(@tiers, &1.id))
      |> Map.new(&{&1.id, Model.new!(&1)})

    %{models: models}
  end

  test "decimal context boundaries select one full-request rate per meter", ctx do
    for {id, {threshold, maximum, short, long}} <- @tiers,
        {tokens, expected} <- [
          {threshold - 1, short},
          {threshold, short},
          {threshold + 1, long},
          {maximum, long}
        ] do
      selection = Pricing.components_for(ctx.models[id], request(input_tokens: tokens))

      assert selection.unresolved == []
      assert length(selection.components) == 4
      assert Enum.all?(selection.components, &(&1.charge_scope == "full_request"))
      assert_rates(selection, expected)
    end
  end

  test "cache savings do not move a request below its total-input price threshold", ctx do
    selection =
      Pricing.components_for(
        ctx.models["qwen3.7-plus"],
        request(input_tokens: 256_001, cache_read_tokens: 250_000)
      )

    assert_rates(selection, [1.2, 4.8, 0.12, 1.5])
  end

  test "Qwen3.7-Plus explicit and implicit cache rates are mutually exclusive", ctx do
    for {tokens, expected} <- [{256_000, [0.4, 1.6, 0.08]}, {256_001, [1.2, 4.8, 0.24]}] do
      selection =
        Pricing.components_for(
          ctx.models["qwen3.7-plus"],
          request(input_tokens: tokens, cache_mode: "implicit")
        )

      assert selection.unresolved == []
      assert length(selection.components) == 3
      assert_rates(selection, expected, Enum.take(@meters, 3))
      refute Enum.any?(selection.components, &(&1.meter == "cache_write_tokens"))
    end

    for id <- ~w(qwen3.6-plus qwen3.6-max-preview) do
      selection = Pricing.components_for(ctx.models[id], request(cache_mode: "implicit"))
      assert Enum.map(selection.components, & &1.meter) == ~w(input_tokens output_tokens)
    end
  end

  test "missing counts or deployment scope never silently select a known rate", ctx do
    for model <- Map.values(ctx.models),
        overrides <- [[input_tokens: nil], [region: nil], [deployment: nil]] do
      selection = Pricing.components_for(model, request(overrides))
      assert selection.components == []
      assert length(selection.unresolved) == if(overrides == [input_tokens: nil], do: 8, else: 4)
    end

    for model <- Map.values(ctx.models),
        overrides <- [[region: "beijing"], [deployment: "global"]] do
      assert Pricing.components_for(model, request(overrides)) == %{
               components: [],
               unresolved: []
             }
    end
  end

  test "cache mode uncertainty is visible and Batch never receives cache discounts", ctx do
    for model <- Map.values(ctx.models) do
      selection = Pricing.components_for(model, request(cache_mode: nil))
      assert length(selection.components) == 2

      assert Enum.all?(
               selection.unresolved,
               &(&1.meter in ~w(cache_read_tokens cache_write_tokens))
             )

      batch = Pricing.components_for(model, request(api: "batch", cache_mode: nil))
      assert batch.unresolved == []
      assert Enum.map(batch.components, & &1.meter) == ~w(input_tokens output_tokens)
    end
  end

  test "rates above the documented maximum stay absent", ctx do
    for {id, {_threshold, maximum, _short, _long}} <- @tiers do
      assert Pricing.components_for(ctx.models[id], request(input_tokens: maximum + 1)) == %{
               components: [],
               unresolved: []
             }
    end
  end

  test "legacy summaries retain list prices and cannot restore unconditional cache rates", ctx do
    for {id, {_threshold, _maximum, short, _long}} <- @tiers do
      model = ctx.models[id]
      assert Enum.map([:input, :output, :cache_read, :cache_write], &model.cost[&1]) == short
      assert model.pricing.currency == "USD"
      assert model.extra.pricing.price_basis == "list"
      assert model.extra.pricing.sources_checked_at == "2026-09-22"

      [reapplied] = Pricing.apply_cost_components([model])

      assert Enum.sort_by(reapplied.pricing.components, & &1.id) ==
               Enum.sort_by(model.pricing.components, & &1.id)

      assert Pricing.apply_cost_components([reapplied]) == [reapplied]
    end
  end

  defp request(overrides) do
    Keyword.merge(
      [
        input_tokens: 10_000,
        region: "singapore",
        deployment: "international",
        api: "chat",
        cache_mode: "explicit"
      ],
      overrides
    )
  end

  defp assert_rates(selection, expected, meters \\ @meters) do
    assert Enum.sort(Enum.map(selection.components, & &1.meter)) == Enum.sort(meters)

    for {meter, rate} <- Enum.zip(meters, expected) do
      component = Enum.find(selection.components, &(&1.meter == meter))
      assert component.per == 1_000_000
      assert component.mode == "standard"
      assert component.source == "provider_docs"
      assert_in_delta component.rate, rate, 1.0e-9
    end
  end
end
