defmodule LLMDB.Sources.XAITest do
  use ExUnit.Case, async: true

  alias LLMDB.{Merge, Model, Pricing}
  alias LLMDB.Sources.XAI

  describe "transform/1" do
    test "preserves token pricing returned by the xAI models endpoint" do
      result =
        XAI.transform(%{
          "object" => "list",
          "data" => [
            %{
              "id" => "grok-4.3",
              "object" => "model",
              "created" => 1_776_384_000,
              "owned_by" => "xai",
              "aliases" => ["grok-4.3-latest", "grok-latest"],
              "context_length" => 1_000_000,
              "prompt_text_token_price" => 12_500,
              "cached_prompt_text_token_price" => 2_000,
              "completion_text_token_price" => 25_000,
              "prompt_image_token_price" => 12_500,
              "long_context_threshold" => 200_000,
              "prompt_text_token_price_long_context" => 25_000,
              "cached_prompt_text_token_price_long_context" => 4_000,
              "completion_text_token_price_long_context" => 50_000
            }
          ]
        })

      [model] = result["xai"].models

      assert model.id == "grok-4.3"
      assert model.provider == :xai
      assert model.extra.created == 1_776_384_000
      assert model.extra.owned_by == "xai"
      assert model.extra.long_context_threshold == 200_000
      assert model.aliases == ["grok-4.3-latest", "grok-latest"]
      assert model.limits.context == 1_000_000

      assert model.cost.input == 1.25
      assert model.cost.cache_read == 0.2
      assert model.cost.output == 2.5
      assert model.cost.image == 1.25

      components = Map.new(model.pricing.components, &{&1.id, &1})

      assert components["token.input.long_context"].rate == 2.5
      assert components["token.cache_read.long_context"].rate == 0.4
      assert components["token.output.long_context"].rate == 5.0
    end

    test "the inclusive prompt threshold selects one full-request rate per meter" do
      [model] = XAI.transform(%{"data" => [priced_model()]})["xai"].models
      [model] = Pricing.apply_cost_components([Model.new!(model)])

      # The official pricing table specifies < 200k / >= 200k prompt tokens:
      # https://docs.x.ai/developers/pricing
      for {tokens, rates} <- [
            {199_999, [2.0, 0.5, 6.0]},
            {200_000, [4.0, 1.0, 12.0]},
            {200_001, [4.0, 1.0, 12.0]}
          ] do
        selected = Pricing.components_for(model, input_tokens: tokens)
        assert selected.unresolved == []
        assert length(selected.components) == 3

        assert Map.new(selected.components, &{&1.meter, &1.rate}) ==
                 Map.new(Enum.zip(~w(input_tokens cache_read_tokens output_tokens), rates))

        assert Enum.all?(selected.components, &(&1.charge_scope == "full_request"))
        assert Enum.all?(selected.components, &(&1.source == "provider_api"))
      end

      assert Pricing.components_for(model).components == []
      assert length(Pricing.components_for(model).unresolved) == 6
      assert Pricing.apply_cost_components([model]) == [model]
    end

    test "older caches without tier fields preserve legacy prices" do
      for threshold <- [nil, "200000", 0, -1] do
        raw = Map.put(priced_model(), "long_context_threshold", threshold)
        [model] = XAI.transform(%{"data" => [raw]})["xai"].models
        refute Map.has_key?(model, :pricing)
        assert model.cost.input == 2.0
        assert model.cost.cache_read == 0.5
        assert model.cost.output == 6.0
      end

      [model] = XAI.transform(%{"data" => [%{"id" => "grok-legacy"}]})["xai"].models
      refute Map.has_key?(model, :pricing)
      refute Map.has_key?(model, :cost)
    end

    test "missing long-context rates do not turn the short rate into an unrestricted fallback" do
      raw = Map.delete(priced_model(), "cached_prompt_text_token_price_long_context")
      [model] = XAI.transform(%{"data" => [raw]})["xai"].models
      [model] = Pricing.apply_cost_components([Model.new!(model)])

      selected = Pricing.components_for(model, input_tokens: 200_000)
      refute Enum.any?(selected.components, &(&1.meter == "cache_read_tokens"))
      assert model.cost.cache_read == 0.5
    end

    test "missing API base rates cannot resurrect aggregate costs as unconditional prices" do
      raw = Map.delete(priced_model(), "cached_prompt_text_token_price")
      [api_model] = XAI.transform(%{"data" => [raw]})["xai"].models
      aggregate = %{id: raw["id"], provider: :xai, cost: %{cache_read: 0.25}}
      [merged] = Merge.merge_models([aggregate], [api_model], %{})
      [model] = Pricing.apply_cost_components([Model.new!(merged)])

      short = Pricing.components_for(model, input_tokens: 199_999)
      cache = Enum.find(short.components, &(&1.meter == "cache_read_tokens"))
      assert cache.id == "token.cache_read"
      assert is_nil(cache[:rate])

      long = Pricing.components_for(model, input_tokens: 200_000)
      [cache] = Enum.filter(long.components, &(&1.meter == "cache_read_tokens"))
      assert cache.id == "token.cache_read.long_context"
      assert cache.rate == 1.0
      assert model.cost.cache_read == 0.25
    end
  end

  defp priced_model do
    %{
      "id" => "grok-4.6",
      "prompt_text_token_price" => 20_000,
      "cached_prompt_text_token_price" => 5_000,
      "completion_text_token_price" => 60_000,
      "long_context_threshold" => 200_000,
      "prompt_text_token_price_long_context" => 40_000,
      "cached_prompt_text_token_price_long_context" => 10_000,
      "completion_text_token_price_long_context" => 120_000
    }
  end
end
