defmodule LLMDB.PricingMergeTest do
  use ExUnit.Case, async: false

  alias LLMDB.{Engine, Merge, Model, Pricing}

  @input %{
    id: "token.input",
    kind: "token",
    unit: "token",
    per: 1_000_000,
    rate: 2.0,
    applies_when: %{input_tokens: %{lt: 200_000}}
  }
  @long %{
    id: "token.input.long_context",
    kind: "token",
    unit: "token",
    per: 1_000_000,
    rate: 4.0,
    applies_when: %{input_tokens: %{gte: 200_000}}
  }
  @modifier %{
    id: "pricing.priority",
    kind: "other",
    unit: "other",
    multiplier: 2.0,
    applies_to: ["token.*"],
    applies_when: %{service_tier: "priority"}
  }

  test "build and runtime overlays preserve API context bands when adding a modifier" do
    for model <- merged_models(%{components: [@modifier], merge: "merge_by_id"}) do
      for {tokens, expected} <- [{199_999, 2.0}, {200_000, 4.0}] do
        selection = Pricing.components_for(model, input_tokens: tokens, service_tier: "priority")
        assert selection.unresolved == []
        assert length(selection.components) == 2
        assert Enum.find(selection.components, &(&1.kind == "token")).rate == expected
        assert Enum.find(selection.components, &(&1.kind == "other")) == @modifier
      end
    end
  end

  test "matching IDs replace entire components and do not duplicate on repeated overlays" do
    override = Map.delete(@input, :applies_when) |> Map.put(:rate, 3.0)

    for model <- merged_models(%{components: [override]}) do
      assert Enum.find(model.pricing.components, &(&1.id == "token.input")) == override
      assert length(model.pricing.components) == 2
      [again] = Merge.merge_models([model], [model], %{})
      assert again.pricing == model.pricing
    end
  end

  test "explicit replace discards lower-precedence components, including an empty list" do
    for components <- [[@modifier], []],
        model <- merged_models(%{components: components, merge: "replace"}) do
      assert model.pricing.components == components
    end
  end

  test "lower precedence retains the base component for matching IDs" do
    base = %{pricing: %{components: [@input]}}
    override = %{pricing: %{components: [Map.put(@input, :rate, 9.0), @modifier]}}
    assert Merge.merge(base, override, :lower).pricing.components == [@input, @modifier]
  end

  test "pricing provenance remains ordinary nested metadata" do
    base = %{extra: %{pricing: %{nested: %{first: true}}}}
    overlay = %{extra: %{pricing: %{nested: %{second: true}}}}
    expected = %{extra: %{pricing: %{nested: %{first: true, second: true}}}}
    assert Merge.deep_merge(base, overlay, Merge.resolver()) == expected
    assert Merge.merge(base, overlay, :higher) == expected
  end

  defp merged_models(pricing) do
    base = %{id: "priced", provider: :openai, pricing: %{components: [@input, @long]}}
    overlay = %{id: "priced", provider: :openai, pricing: pricing}

    sources =
      for model <- [base, overlay] do
        {LLMDB.Sources.Config, %{overrides: %{providers: [%{id: :openai}], models: [model]}}}
      end

    assert {:ok, snapshot} = Engine.run(sources: sources)
    [runtime] = Merge.merge_models([base], [overlay], %{})
    [snapshot.providers.openai.models["priced"], Model.new!(runtime)]
  end
end
