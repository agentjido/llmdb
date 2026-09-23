defmodule LLMDB.ConditionalPricingMetadataTest do
  use ExUnit.Case, async: true

  alias LLMDB.{Loader, Model, Normalize, Pricing}
  alias LLMDB.Sources.Local

  @openai %{
    "gpt-6-astra" => [10.0, 50.0, 1.0, 12.5],
    "gpt-6-sol" => [2.0, 10.0, 0.2, 2.5],
    "gpt-6-luna" => [0.1, 0.5, 0.01, 0.125]
  }
  @anthropic %{
    "claude-fable-5-1" => [10.0, 50.0, 0.25, 12.5],
    "claude-opus-5-5" => [4.0, 20.0, 0.2, 5.0],
    "claude-opus-5" => [5.0, 25.0, 0.5, 6.25],
    "claude-sonnet-5" => [2.0, 10.0, 0.2, 2.5],
    "claude-haiku-4-5-20251001" => [1.0, 5.0, 0.1, 1.25]
  }
  @meters ~w(input_tokens output_tokens cache_read_tokens cache_write_tokens)

  setup_all do
    {:ok, data} = Local.load(%{dir: "priv/llm_db/local"})

    models =
      for {provider, expected} <- [{"openai", @openai}, {"anthropic", @anthropic}],
          model <- Normalize.normalize_models(data[provider].models),
          Map.has_key?(expected, model.id),
          into: %{} do
        {model.id, Model.new!(model)}
      end

    %{models: models}
  end

  test "GPT-6 selects exactly one full-request rate per meter on both sides of 272K", ctx do
    for {id, short_rates} <- @openai,
        {tokens, factors} <- [{272_000, [1, 1, 1, 1]}, {272_001, [2, 1.5, 2, 2]}] do
      model = ctx.models[id]
      selection = Pricing.components_for(model, openai_context(input_tokens: tokens))
      assert selection.unresolved == []
      assert length(selection.components) == 4
      assert Enum.all?(selection.components, &(&1.charge_scope == "full_request"))
      assert_rates(selection, Enum.zip_with(short_rates, factors, &(&1 * &2)))
      assert legacy_rates(model) == short_rates
    end
  end

  test "GPT-6 processing modifiers stack with context and residency exactly once", ctx do
    for id <- Map.keys(@openai),
        tokens <- [272_000, 272_001],
        {api, tier, multiplier} <- [
          {"responses", "default", 1.0},
          {"batch", "default", 0.5},
          {"responses", "flex", 0.5},
          {"responses", "fast", 2.0},
          {"responses", "priority", 2.0}
        ] do
      selection =
        Pricing.components_for(
          ctx.models[id],
          openai_context(
            api: api,
            service_tier: tier,
            input_tokens: tokens,
            regional_processing: true
          )
        )

      assert selection.unresolved == []
      factors = if tokens > 272_000, do: [2, 1.5, 2, 2], else: [1, 1, 1, 1]
      expected = Enum.zip_with(@openai[id], factors, &(&1 * &2 * multiplier * 1.1))
      assert_rates(selection, expected)
    end
  end

  test "GPT-6 records documented effort choices without inventing per-effort prices", ctx do
    for id <- ~w(gpt-6-sol gpt-6-luna) do
      model = ctx.models[id]
      assert model.capabilities.reasoning.effort.values == ~w(none low medium high xhigh max)
      assert model.capabilities.reasoning.effort.default == "medium"

      assert Pricing.components_for(model, openai_context(reasoning_effort: "max")) ==
               Pricing.components_for(model, openai_context(reasoning_effort: "none"))
    end
  end

  test "incomplete context cannot silently select a short-context or standard-only price", ctx do
    for id <- Map.keys(@openai) do
      selection = Pricing.components_for(ctx.models[id])
      assert selection.components == []
      assert length(selection.unresolved) == 13

      selection = Pricing.components_for(ctx.models[id], input_tokens: nil)
      assert selection.components == []
      assert length(selection.unresolved) == 13
    end
  end

  test "Claude cache TTLs and Batch apply to every token category", ctx do
    for {id, [input, output, read, write]} <- @anthropic,
        {ttl, write_rate} <- [{"5m", write}, {"1h", 2 * input}],
        {api, discount} <- [{"messages", 1.0}, {"batch", 0.5}] do
      model = ctx.models[id]
      selection = Pricing.components_for(model, anthropic_context(api: api, cache_ttl: ttl))
      assert selection.unresolved == []
      assert_rates(selection, Enum.map([input, output, read, write_rate], &(&1 * discount)))
      assert legacy_rates(model) == [input, output, read, write]
    end
  end

  test "Claude uses model-specific cache read ratios and US-only residency", ctx do
    for {id, expected} <- [
          {"claude-fable-5-1", [5.5, 27.5, 0.1375, 11.0]},
          {"claude-opus-5-5", [2.2, 11.0, 0.11, 4.4]},
          {"claude-opus-5", [2.75, 13.75, 0.275, 5.5]},
          {"claude-sonnet-5", [1.1, 5.5, 0.11, 2.2]}
        ] do
      selection =
        Pricing.components_for(
          ctx.models[id],
          anthropic_context(api: "batch", cache_ttl: "1h", inference_geo: "us")
        )

      assert selection.unresolved == []
      assert_rates(selection, expected)
    end

    haiku = ctx.models["claude-haiku-4-5-20251001"]
    refute Enum.any?(haiku.pricing.components, &(&1.id == "pricing.data_residency"))
  end

  test "Opus fast mode stacks with cache and residency but is excluded for Batch", ctx do
    for {id, expected} <- [
          {"claude-opus-5-5", [8.8, 44.0, 0.44, 17.6]},
          {"claude-opus-5", [11.0, 55.0, 1.1, 22.0]}
        ] do
      selection =
        Pricing.components_for(
          ctx.models[id],
          anthropic_context(
            request_body: %{speed: "fast"},
            cache_ttl: "1h",
            inference_geo: "us"
          )
        )

      assert selection.unresolved == []
      assert_rates(selection, expected)

      batch = Pricing.components_for(ctx.models[id], api: "batch")
      refute Enum.any?(batch.components ++ batch.unresolved, &(&1.id == "pricing.fast"))
    end
  end

  test "Claude does not acquire a long-context surcharge from unrelated provider rules", ctx do
    for id <- ~w(claude-fable-5-1 claude-opus-5-5 claude-opus-5 claude-sonnet-5) do
      assert Pricing.components_for(ctx.models[id], anthropic_context(input_tokens: 9_000)) ==
               Pricing.components_for(ctx.models[id], anthropic_context(input_tokens: 900_000))
    end
  end

  test "unknown cache duration is unresolved, and mixed TTL usage can be selected separately",
       ctx do
    model = ctx.models["claude-fable-5-1"]
    selection = Pricing.components_for(model, anthropic_context(cache_ttl: nil))

    assert Enum.map(selection.unresolved, & &1.id) == [
             "token.cache_write",
             "token.cache_write.1h"
           ]

    five_minutes = Pricing.components_for(model, anthropic_context(cache_ttl: "5m"))
    one_hour = Pricing.components_for(model, anthropic_context(cache_ttl: "1h"))
    assert_rates(five_minutes, [10.0, 50.0, 0.25, 12.5])
    assert_rates(one_hour, [10.0, 50.0, 0.25, 20.0])
  end

  test "packaged loading preserves curated components and provider tools without duplication",
       ctx do
    assert {:ok, loaded} =
             Loader.load(
               allow: %{openai: Map.keys(@openai), anthropic: Map.keys(@anthropic)},
               deny: %{},
               prefer: [],
               custom: %{}
             )

    assert Enum.sum(Enum.map(Map.values(loaded.models), &length/1)) == 8

    for provider <- [:openai, :anthropic], model <- loaded.models[provider] do
      expected = ctx.models[model.id]
      curated = Enum.reject(model.pricing.components, &(&1.kind in ["tool", "storage"]))
      assert json_components(curated) == json_components(expected.pricing.components)
      [reapplied] = Pricing.apply_cost_components([model])

      assert json_components(reapplied.pricing.components) ==
               json_components(model.pricing.components)

      assert Pricing.apply_cost_components([reapplied]) == [reapplied]

      assert length(Enum.uniq_by(model.pricing.components, & &1.id)) ==
               length(model.pricing.components)

      assert Enum.any?(model.pricing.components, &(&1.kind == "tool"))
    end
  end

  # This arithmetic checks the curated relationships, not a general billing API.
  # Derive first, then apply each token-wide modifier once to each resulting rate.
  defp assert_rates(selection, expected) do
    tokens = Enum.filter(selection.components, &(&1.kind == "token"))
    assert Enum.sort(Enum.map(tokens, & &1.meter)) == Enum.sort(@meters)
    by_id = Map.new(tokens, &{&1.id, &1})

    multiplier =
      selection.components
      |> Enum.filter(&(&1.kind == "other"))
      |> Enum.reduce(1.0, fn modifier, acc ->
        assert modifier.applies_to == ["token.*"]
        acc * modifier.multiplier
      end)

    for {meter, rate} <- Enum.zip(@meters, expected) do
      component = Enum.find(tokens, &(&1.meter == meter))
      assert component.per == 1_000_000

      base_rate =
        if component[:derives_from] do
          by_id[component.derives_from].rate * component.multiplier
        else
          component.rate
        end

      assert_in_delta base_rate * multiplier, rate, 1.0e-9
    end
  end

  defp openai_context(overrides) do
    Keyword.merge(
      [
        api: "responses",
        service_tier: "default",
        regional_processing: false,
        input_tokens: 1_000
      ],
      overrides
    )
  end

  defp anthropic_context(overrides) do
    Keyword.merge(
      [
        api: "messages",
        request_body: %{speed: "standard"},
        inference_geo: "global",
        cache_ttl: "5m"
      ],
      overrides
    )
  end

  defp legacy_rates(model) do
    Enum.map([:input, :output, :cache_read, :cache_write], &Map.fetch!(model.cost, &1))
  end

  defp json_components(components) do
    components |> Enum.sort_by(& &1.id) |> Jason.encode!() |> Jason.decode!()
  end
end
