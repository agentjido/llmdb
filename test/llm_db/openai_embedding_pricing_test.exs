defmodule LLMDB.OpenAIEmbeddingPricingTest do
  use ExUnit.Case, async: true

  alias LLMDB.{Model, Normalize}
  alias LLMDB.Sources.Local

  @expected %{
    "text-embedding-3-small" =>
      {0.02, "https://developers.openai.com/api/docs/models/text-embedding-3-small"},
    "text-embedding-3-large" =>
      {0.13, "https://developers.openai.com/api/docs/models/text-embedding-3-large"},
    "text-embedding-ada-002" =>
      {0.10, "https://developers.openai.com/api/docs/models/text-embedding-ada-002"}
  }

  setup_all do
    {:ok, data} = Local.load(%{dir: "priv/llm_db/local"})

    models =
      data["openai"].models
      |> Normalize.normalize_models()
      |> Enum.filter(&Map.has_key?(@expected, &1.id))
      |> Map.new(fn model ->
        model = Model.new!(model)
        {model.id, model}
      end)

    %{models: models}
  end

  test "embedding prices use the per-million-token unit and record their sources", %{
    models: models
  } do
    assert MapSet.new(Map.keys(models)) == MapSet.new(Map.keys(@expected))

    for {id, {input_price, source_url}} <- @expected do
      model = Map.fetch!(models, id)
      assert model.cost.input == input_price
      assert model.extra.pricing.sources_checked_at == "2026-11-07"
      assert model.extra.pricing.source_urls == [source_url]
    end
  end
end
