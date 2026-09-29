defmodule LLMDB.OpenAIDevDayTest do
  use ExUnit.Case, async: true

  alias LLMDB.{Model, Normalize, Packaged, Pricing}
  alias LLMDB.Sources.Local

  test "Sol 6.1 records the Responses contract and restricted reasoning efforts" do
    model = model("gpt-6.1-sol")
    assert model.limits == %{context: 1_050_000, input: 922_000, output: 128_000}
    assert model.capabilities.reasoning.effort.values == ~w(low medium high xhigh max)
    assert model.capabilities.reasoning.effort.default == "medium"
    assert model.extra.wire.protocol == "openai_responses"
    assert model.extra.multi_agent.required_header == "responses_multi_agent=v1"
    assert model.cost == %{input: 2.0, output: 10.0, cache_read: 0.1, cache_write: 2.5}
  end

  test "Sol 6.1 selects the correct cache and output rates across the context boundary" do
    for {tokens, expected} <- [
          {272_000,
           %{
             input_tokens: 2.0,
             output_tokens: 10.0,
             cache_read_tokens: 0.1,
             cache_write_tokens: 2.5
           }},
          {272_001,
           %{
             input_tokens: 4.0,
             output_tokens: 15.0,
             cache_read_tokens: 0.2,
             cache_write_tokens: 5.0
           }}
        ] do
      selection =
        Pricing.components_for(model("gpt-6.1-sol"),
          input_tokens: tokens,
          api: "responses",
          service_tier: "default",
          regional_processing: false
        )

      assert selection.unresolved == []

      assert Map.new(selection.components, &{String.to_existing_atom(&1.meter), &1.rate}) ==
               expected
    end
  end

  test "Astra Ultrafast has one six-times modifier and excludes batch" do
    model = model("gpt-6-astra")

    selection =
      Pricing.components_for(model,
        input_tokens: 272_000,
        api: "responses",
        service_tier: "ultrafast",
        regional_processing: false
      )

    assert selection.unresolved == []
    assert [%{multiplier: 6.0}] = Enum.filter(selection.components, &(&1.kind == "other"))

    batch =
      Pricing.components_for(model,
        input_tokens: 272_000,
        api: "batch",
        service_tier: "ultrafast",
        regional_processing: false
      )

    refute Enum.any?(batch.components, &(&1.id == "pricing.ultrafast"))
  end

  test "packaged Sol 6.1 exposes text and object Responses execution" do
    model = Packaged.snapshot()["providers"]["openai"]["models"]["gpt-6.1-sol"]
    assert model["cost"]["cache_read"] == 0.1

    for operation <- ["text", "object"] do
      assert model["execution"][operation] == %{
               "family" => "openai_responses_compatible",
               "path" => "/responses",
               "supported" => true,
               "wire_protocol" => "openai_responses"
             }
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
