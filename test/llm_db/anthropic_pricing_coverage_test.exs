defmodule LLMDB.AnthropicPricingCoverageTest do
  use ExUnit.Case, async: true

  alias LLMDB.{Loader, Model, Pricing}

  @rates %{
    "claude-fable-5" => [10.0, 50.0, 1.0, 12.5],
    "claude-fable-5-1" => [10.0, 50.0, 0.25, 12.5],
    "claude-haiku-4-5-20251001" => [1.0, 5.0, 0.1, 1.25],
    "claude-haiku-5-5" => [0.1, 0.5, 0.01, 0.125],
    "claude-opus-4-20250514" => [15.0, 75.0, 1.5, 18.75],
    "claude-opus-4-1-20250805" => [15.0, 75.0, 1.5, 18.75],
    "claude-opus-4-5-20251101" => [5.0, 25.0, 0.5, 6.25],
    "claude-opus-4-6" => [5.0, 25.0, 0.5, 6.25],
    "claude-opus-4-7" => [5.0, 25.0, 0.5, 6.25],
    "claude-opus-4-8" => [5.0, 25.0, 0.5, 6.25],
    "claude-opus-5" => [5.0, 25.0, 0.5, 6.25],
    "claude-opus-5-5" => [4.0, 20.0, 0.2, 5.0],
    "claude-sonnet-4-20250514" => [3.0, 15.0, 0.3, 3.75],
    "claude-sonnet-4-5-20250929" => [3.0, 15.0, 0.3, 3.75],
    "claude-sonnet-4-6" => [3.0, 15.0, 0.3, 3.75],
    "claude-sonnet-5" => [2.0, 10.0, 0.2, 2.5],
    "claude-sonnet-5-5" => [2.0, 10.0, 0.1, 2.5]
  }
  @residency ~w(claude-fable-5 claude-fable-5-1 claude-haiku-5-5 claude-opus-4-6 claude-opus-4-7 claude-opus-4-8 claude-opus-5 claude-opus-5-5 claude-sonnet-4-6 claude-sonnet-5 claude-sonnet-5-5)
  @fast ~w(claude-opus-4-8 claude-opus-5 claude-opus-5-5)
  @unpriced ~w(claude-3-haiku-20240307 claude-3-5-haiku-20241022 claude-3-7-sonnet-20250219)
  @meters ~w(input_tokens output_tokens cache_read_tokens cache_write_tokens)

  setup_all do
    {:ok, loaded} = Loader.load()
    models = loaded.models |> Map.fetch!(:anthropic) |> Map.new(&{&1.id, &1})
    %{models: models}
  end

  test "every packaged Anthropic model has a reviewed pricing or retirement record", ctx do
    assert MapSet.new(Map.keys(ctx.models)) == MapSet.new(Map.keys(@rates) ++ @unpriced)

    for id <- @unpriced do
      assert Model.retired?(ctx.models[id])
      assert ctx.models[id].cost == nil
      refute Enum.any?(ctx.models[id].pricing.components, &(&1.kind == "token"))
    end

    for id <- Map.keys(@rates) do
      model = ctx.models[id]
      assert get_in(model.extra, ["pricing", "sources_checked_at"]) == "2026-10-09"
      assert :ok == Pricing.validate_components(model.pricing.components)
      [reapplied] = Pricing.apply_cost_components([model])

      assert Enum.sort_by(reapplied.pricing.components, & &1.id) ==
               Enum.sort_by(model.pricing.components, & &1.id)

      assert Pricing.apply_cost_components([reapplied]) == [reapplied]
    end
  end

  test "TTL, Batch, and residency select one rate per token meter for every priced model", ctx do
    for {id, [input, output, read, five]} <- @rates,
        {ttl, write} <- [{"5m", five}, {"1h", 2 * input}],
        {api, batch} <- [{"messages", 1.0}, {"batch", 0.5}],
        geo <- ["global", "us"] do
      region = if geo == "us" and id in @residency, do: 1.1, else: 1.0
      expected = Enum.map([input, output, read, write], &(&1 * batch * region))

      selection =
        Pricing.components_for(
          ctx.models[id],
          context(cache_ttl: ttl, api: api, inference_geo: geo)
        )

      assert_rates(selection, expected)
    end
  end

  test "missing or unsupported TTL cannot select a generic write rate", ctx do
    for id <- Map.keys(@rates) do
      missing = Pricing.components_for(ctx.models[id], context(cache_ttl: nil))
      assert Enum.count(missing.unresolved, &String.starts_with?(&1.id, "token.cache_write")) == 2
      refute Enum.any?(missing.components, &String.starts_with?(&1.id, "token.cache_write"))
      unsupported = Pricing.components_for(ctx.models[id], context(cache_ttl: "2h"))
      refute Enum.any?(unsupported.components, &String.starts_with?(&1.id, "token.cache_write"))
    end
  end

  test "Haiku 5.5 prices the full prompt above 100K with each modifier applied once", ctx do
    for {tokens, band} <- [{100_000, 1.0}, {100_001, 5.0}],
        {ttl, write} <- [{"5m", 0.125}, {"1h", 0.2}],
        {api, batch} <- [{"messages", 1.0}, {"batch", 0.5}],
        {geo, region} <- [{"global", 1.0}, {"us", 1.1}] do
      selection =
        Pricing.components_for(
          ctx.models["claude-haiku-5-5"],
          context(input_tokens: tokens, cache_ttl: ttl, api: api, inference_geo: geo)
        )

      assert_rates(selection, Enum.map([0.1, 0.5, 0.01, write], &(&1 * band * batch * region)))
    end

    missing = Pricing.components_for(ctx.models["claude-haiku-5-5"], context(input_tokens: nil))
    assert Enum.any?(missing.unresolved, &(&1.id == "pricing.long_context"))

    for id <- @residency -- ["claude-haiku-5-5"] do
      assert Pricing.components_for(ctx.models[id], context(input_tokens: 9_000)) ==
               Pricing.components_for(ctx.models[id], context(input_tokens: 900_000))
    end
  end

  test "fast pricing exists only on supported Opus models and never stacks with Batch", ctx do
    for {id, rates} <- @rates do
      fast =
        Pricing.components_for(
          ctx.models[id],
          context(request_body: %{speed: "fast"}, cache_ttl: "1h")
        )

      factor = if id in @fast, do: 2.0, else: 1.0
      [input, output, read, _write] = rates
      assert_rates(fast, Enum.map([input, output, read, 2 * input], &(&1 * factor)))

      batch =
        Pricing.components_for(
          ctx.models[id],
          context(api: "batch", request_body: %{speed: "fast"})
        )

      refute Enum.any?(batch.components ++ batch.unresolved, &(&1.id == "pricing.fast"))
    end
  end

  test "Sonnet 4.5 carries the documented deprecation window", ctx do
    lifecycle = ctx.models["claude-sonnet-4-5-20250929"].lifecycle
    assert lifecycle.status == "deprecated"
    assert lifecycle.deprecated_at == "2026-09-30"
    assert lifecycle.retires_at == "2026-11-30"
    assert lifecycle.replacement == "claude-sonnet-5-5"
  end

  test "retired Claude API models retain their retirement status", ctx do
    for id <-
          @unpriced ++
            ~w(claude-opus-4-20250514 claude-opus-4-1-20250805 claude-sonnet-4-20250514) do
      assert ctx.models[id].lifecycle.status == "retired"
      assert Model.retired?(ctx.models[id])
    end
  end

  defp context(overrides) do
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

  defp assert_rates(selection, expected) do
    assert selection.unresolved == []
    tokens = Enum.filter(selection.components, &(&1.kind == "token"))
    assert Enum.sort(Enum.map(tokens, & &1.meter)) == Enum.sort(@meters)
    by_id = Map.new(tokens, &{&1.id, &1})

    modifier =
      selection.components
      |> Enum.filter(&(&1.kind == "other"))
      |> Enum.reduce(1.0, &(&1.multiplier * &2))

    for {meter, rate} <- Enum.zip(@meters, expected) do
      component = Enum.find(tokens, &(&1.meter == meter))

      base =
        if component[:derives_from],
          do: by_id[component.derives_from].rate * component.multiplier,
          else: component.rate

      assert component.per == 1_000_000
      assert_in_delta base * modifier, rate, 1.0e-9
    end
  end
end
