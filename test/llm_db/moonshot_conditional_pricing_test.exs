defmodule LLMDB.MoonshotConditionalPricingTest do
  use ExUnit.Case, async: true

  alias LLMDB.{Loader, Model, Normalize, Pricing}
  alias LLMDB.Sources.Local

  setup_all do
    {:ok, data} = Local.load(%{dir: "priv/llm_db/local"})

    model =
      data["moonshotai"].models
      |> Normalize.normalize_models()
      |> Enum.find(&(&1.id == "kimi-k3"))
      |> Model.new!()

    [model] = Pricing.apply_cost_components([model])
    %{model: model}
  end

  test "K3 selects one cache-write rate by effective TTL without context tiers", %{model: model} do
    for {ttl, write_rate} <- [{"5m", 3.0}, {"1h", 6.0}],
        input_tokens <- [1_000, 200_000, 1_000_000] do
      selected = Pricing.components_for(model, cache_ttl: ttl, input_tokens: input_tokens)

      assert selected.unresolved == []
      assert length(selected.components) == 4

      assert Map.new(selected.components, &{&1.meter, &1.rate}) == %{
               "input_tokens" => 3.0,
               "output_tokens" => 15.0,
               "cache_read_tokens" => 0.3,
               "cache_write_tokens" => write_rate
             }

      assert Enum.all?(selected.components, &(&1.per == 1_000_000))
      assert Enum.all?(selected.components, &(&1.charge_scope == "full_request"))
      assert Enum.all?(selected.components, &(&1.source == "provider_docs"))
    end

    refute Enum.any?(model.pricing.components, &(&1.id == "pricing.batch"))
    assert model.extra.pricing.long_context_premium == false
    assert model.pricing.currency == "USD"
  end

  test "unknown TTL leaves both write rates unresolved", %{model: model} do
    for context <- [%{}, %{cache_ttl: nil}] do
      selected = Pricing.components_for(model, context)
      assert length(selected.components) == 3
      refute Enum.any?(selected.components, &(&1.meter == "cache_write_tokens"))

      assert Enum.map(selected.unresolved, & &1.id) == [
               "token.cache_write",
               "token.cache_write.1h"
             ]
    end
  end

  test "cost expansion does not reintroduce an unconditional cache-write rate", %{model: model} do
    assert model.cost.input == 3.0
    assert model.cost.output == 15.0
    assert model.cost.cache_read == 0.3
    assert model.cost.cache_write == 3.0
    assert length(model.pricing.components) == 5
    assert Pricing.apply_cost_components([model]) == [model]

    writes = Enum.filter(model.pricing.components, &(&1.meter == "cache_write_tokens"))
    assert Enum.all?(writes, &is_map(&1.applies_when))
    assert model.execution.text.path == "/chat/completions"
    assert model.execution.text.wire_protocol == "openai_chat"
  end

  test "packaged loading preserves both cache durations", %{model: model} do
    assert {:ok, loaded} =
             Loader.load(allow: %{moonshotai: ["kimi-k3"]}, deny: %{}, prefer: [], custom: %{})

    [packaged] = loaded.models.moonshotai

    assert json_components(packaged) == json_components(model)
  end

  test "documented disjoint usage permits cache writes without charging input twice", %{
    model: model
  } do
    # Cache reads + writes + uncached input partition total input in the provider's
    # Chat Completions and Responses usage. This checks metadata, not a billing API.
    usage = %{
      "input_tokens" => 200_000,
      "cache_read_tokens" => 500_000,
      "cache_write_tokens" => 300_000,
      "output_tokens" => 100_000
    }

    for {ttl, expected} <- [{"5m", 3.15}, {"1h", 4.05}] do
      selected = Pricing.components_for(model, cache_ttl: ttl)

      cost =
        Enum.reduce(selected.components, 0.0, fn component, acc ->
          acc + usage[component.meter] / component.per * component.rate
        end)

      assert_in_delta cost, expected, 1.0e-10
    end
  end

  defp json_components(model) do
    model.pricing.components
    |> Enum.sort_by(& &1.id)
    |> Jason.encode!()
    |> Jason.decode!()
  end
end
