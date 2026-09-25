defmodule LLMDB.XAIConditionalPricingTest do
  use ExUnit.Case, async: true

  alias LLMDB.{Merge, Model, Normalize, Pricing}
  alias LLMDB.Sources.{Local, XAI}

  setup_all do
    {:ok, remote} = XAI.load(%{})
    {:ok, local} = Local.load(%{dir: "priv/llm_db/local"})

    models =
      remote["xai"].models
      |> Normalize.normalize_models()
      |> Merge.merge_models(Normalize.normalize_models(local["xai"].models), %{})
      |> Enum.filter(&(&1.id in ~w(grok-4.3 grok-4.6 grok-4.7)))
      |> Enum.map(&Model.new!/1)
      |> Pricing.apply_cost_components()
      |> Map.new(&{&1.id, &1})

    %{models: models}
  end

  test "recent models preserve API context bands when docs-only modifiers are merged", ctx do
    for id <- ~w(grok-4.3 grok-4.6 grok-4.7),
        tokens <- [199_999, 200_000, 200_001] do
      model = ctx.models[id]
      selected = Pricing.components_for(model, context(input_tokens: tokens))

      assert selected.unresolved == []
      assert length(selected.components) == 3
      assert Enum.all?(selected.components, &(&1.charge_scope == "full_request"))

      expected = if id == "grok-4.3", do: [1.25, 0.2, 2.5], else: [2.0, 0.5, 6.0]
      multiplier = if tokens < 200_000, do: 1, else: 2
      assert_rates(selected.components, Enum.map(expected, &(&1 * multiplier)))
      assert Pricing.apply_cost_components([model]) == [model]
    end
  end

  test "priority and US endpoint modifiers stack with long context on supported models", ctx do
    for id <- ~w(grok-4.6 grok-4.7), tokens <- [199_999, 200_000] do
      selected =
        Pricing.components_for(
          ctx.models[id],
          context(
            input_tokens: tokens,
            service_tier: "priority",
            base_url: "https://us.api.x.ai/v1"
          )
        )

      assert selected.unresolved == []
      multiplier = if tokens < 200_000, do: 2.2, else: 4.4
      assert_rates(selected.components, Enum.map([2.0, 0.5, 6.0], &(&1 * multiplier)))
    end
  end

  test "Batch discounts are model-specific and exclude priority pricing", ctx do
    selected =
      Pricing.components_for(
        ctx.models["grok-4.3"],
        context(api: "batch", service_tier: "priority", input_tokens: 200_000)
      )

    assert selected.unresolved == []
    assert_rates(selected.components, [2.0, 0.32, 4.0])
    refute Enum.any?(selected.components, &(&1.id == "pricing.priority"))

    for id <- ~w(grok-4.6 grok-4.7) do
      refute Enum.any?(ctx.models[id].pricing.components, &(&1.id == "pricing.batch"))
    end
  end

  test "missing request context leaves rates and modifiers unresolved", ctx do
    for id <- ~w(grok-4.3 grok-4.6 grok-4.7) do
      selected = Pricing.components_for(ctx.models[id])
      assert selected.components == []
      assert length(selected.unresolved) == 8
    end
  end

  defp context(overrides) do
    Keyword.merge(
      [
        api: "responses",
        service_tier: "default",
        base_url: "https://api.x.ai/v1",
        input_tokens: 1_000
      ],
      overrides
    )
  end

  defp assert_rates(components, expected) do
    tokens = Enum.filter(components, &(&1.kind == "token"))
    assert length(tokens) == 3
    by_meter = Map.new(tokens, &{&1.meter, &1})

    multiplier =
      components
      |> Enum.filter(&(&1.kind == "other"))
      |> Enum.reduce(1.0, fn modifier, total ->
        assert modifier.applies_to == ["token.*"]
        total * modifier.multiplier
      end)

    for {meter, rate} <- Enum.zip(~w(input_tokens cache_read_tokens output_tokens), expected) do
      component = Map.fetch!(by_meter, meter)
      assert_in_delta component.rate * multiplier, rate, 1.0e-10
    end
  end
end
