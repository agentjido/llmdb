defmodule LLMDB.OpenRouterMistralCachePricingTest do
  use ExUnit.Case, async: true

  alias LLMDB.{Model, Normalize, Pricing}
  alias LLMDB.Sources.Local

  test "prices cached Mistral Medium 3.5 tokens at the standard input rate" do
    {:ok, data} = Local.load(%{dir: "priv/llm_db/local"})

    override =
      data
      |> Map.fetch!("openrouter")
      |> Map.fetch!(:models)
      |> Normalize.normalize_models()
      |> Enum.map(&Model.new!/1)
      |> Enum.find(&(&1.id == "mistralai/mistral-medium-3-5"))

    model = %{override | cost: Map.merge(%{input: 1.5, output: 7.5}, override.cost)}
    [model] = Pricing.apply_cost_components([model])

    components = Map.new(model.pricing.components, &{&1.id, &1})
    assert components["token.cache_read"].rate == components["token.input"].rate

    input = (3972 - 1792) * components["token.input"].rate / 1_000_000
    cached = 1792 * components["token.cache_read"].rate / 1_000_000
    output = 2149 * components["token.output"].rate / 1_000_000
    assert_in_delta input + cached + output, 0.0220755, 1.0e-10

    assert "https://github.com/agentjido/req_llm/issues/1096" in model.extra.source_urls
  end
end
