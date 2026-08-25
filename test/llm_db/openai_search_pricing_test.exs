defmodule LLMDB.OpenAISearchPricingTest do
  use ExUnit.Case, async: true

  alias LLMDB.{Model, Normalize, Pricing}
  alias LLMDB.Sources.Local

  @local_dir "priv/llm_db/local"
  @model_ids ["gpt-5-search-api", "gpt-5-search-api-2025-10-14"]

  test "GPT-5 Search API aliases use the documented token prices" do
    models = openai_models()

    Enum.each(@model_ids, fn model_id ->
      model = Map.fetch!(models, model_id)

      assert model.cost.input == 1.25
      assert model.cost.cache_read == 0.125
      assert model.cost.output == 10.0

      [priced_model] = Pricing.apply_cost_components([model])
      components = Map.new(priced_model.pricing.components, &{&1.id, &1.rate})

      assert components["token.input"] == 1.25
      assert components["token.cache_read"] == 0.125
      assert components["token.output"] == 10.0
    end)
  end

  defp openai_models do
    {:ok, data} = Local.load(%{dir: @local_dir})

    data
    |> Map.fetch!("openai")
    |> Map.fetch!(:models)
    |> Normalize.normalize_models()
    |> Enum.map(&Model.new!/1)
    |> Map.new(&{&1.id, &1})
  end
end
