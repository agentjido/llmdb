defmodule LLMDB.OpenAIGPT62Test do
  use ExUnit.Case, async: true

  alias LLMDB.{Model, Normalize, Pricing}
  alias LLMDB.Sources.Local

  @ids ~w(gpt-6.2-astra gpt-6.2-sol)

  test "GPT-6.2 models record the documented API contract" do
    for id <- @ids do
      model = model(id)

      assert model.provider_model_id == id
      assert model.release_date == "2026-11-17"
      assert model.limits == %{context: 1_050_000, input: 922_000, output: 128_000}
      assert model.modalities == %{input: [:text, :image], output: [:text]}
      assert model.capabilities.reasoning.enabled
      assert model.capabilities.reasoning.effort.values == ~w(low medium high xhigh max)
      assert model.capabilities.tools.enabled
      assert model.capabilities.json.schema
      assert model.capabilities.json.strict
      assert model.capabilities.streaming.text
      assert model.capabilities.batch.supported
      assert model.extra.wire.protocol == "openai_responses"
      assert model.extra.multi_agent.supported
    end
  end

  test "GPT-6.2 standard prices and long-context prices match provider documentation" do
    expected = %{
      "gpt-6.2-astra" => [
        {272_000, [8.0, 40.0, 0.4, 10.0]},
        {272_001, [16.0, 60.0, 0.8, 20.0]}
      ],
      "gpt-6.2-sol" => [
        {272_000, [2.0, 10.0, 0.1, 2.5]},
        {272_001, [4.0, 15.0, 0.2, 5.0]}
      ]
    }

    for {id, tiers} <- expected, {input_tokens, rates} <- tiers do
      selection =
        Pricing.components_for(model(id),
          input_tokens: input_tokens,
          api: "responses",
          service_tier: "default",
          regional_processing: false
        )

      assert selection.unresolved == []
      assert Enum.map(selection.components, & &1.rate) == rates
    end
  end

  test "GPT-6.2 Ultrafast uses the current introductory multiplier" do
    for id <- @ids do
      selection =
        Pricing.components_for(model(id),
          input_tokens: 272_000,
          api: "responses",
          service_tier: "ultrafast",
          regional_processing: false
        )

      assert selection.unresolved == []

      assert [%{id: "pricing.ultrafast", multiplier: 3.0}] =
               Enum.filter(selection.components, &(&1.kind == "other"))
    end
  end

  defp model(id) do
    {:ok, data} = Local.load(%{dir: "priv/llm_db/local"})

    data["openai"].models
    |> Normalize.normalize_models()
    |> Enum.find(&(&1.id == id))
    |> Model.new!()
  end
end
