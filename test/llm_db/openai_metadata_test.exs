defmodule LLMDB.OpenAIMetadataTest do
  use ExUnit.Case, async: true

  alias LLMDB.{Model, Normalize, Packaged, Pricing}
  alias LLMDB.Sources.Local

  @local_dir "priv/llm_db/local"

  test "Astra metadata records documented limits and limited access" do
    model = astra_model()

    assert model.provider_model_id == "gpt-6-astra"
    assert model.name == "GPT-6 Astra"
    assert model.release_date == "2026-09-03"
    assert model.knowledge == "2026-04-30"
    assert model.aliases == []
    assert model.limits == %{context: 1_050_000, input: 922_000, output: 128_000}
    assert model.modalities == %{input: [:text, :image], output: [:text]}
    assert model.extra.availability == "limited"
    assert model.extra.availability_updated == "2026-09-03"
    assert model.extra.availability_note =~ "Trusted Access Program"
    assert model.extra.wire.protocol == "openai_responses"
    assert model.extra.tool_calling_endpoint == "/v1/responses"

    assert model.capabilities.reasoning.enabled
    assert model.capabilities.reasoning.effort.supported
    assert model.capabilities.reasoning.effort.values == ["low", "medium", "high", "xhigh", "max"]
    assert is_nil(model.capabilities.reasoning.effort[:default])
    assert model.capabilities.tools.enabled
    assert model.capabilities.json.schema
    assert model.capabilities.streaming.text
    assert model.capabilities.batch.supported
    assert model.capabilities.code_execution.supported
  end

  test "Astra pricing selects one full-request rate per meter at the 272K boundary" do
    model = astra_model()
    assert model.cost == %{input: 10.0, output: 50.0, cache_read: 1.0, cache_write: 12.5}

    for {input_tokens, suffix, expected_rates} <- [
          {272_000, "",
           %{"input" => 10.0, "output" => 50.0, "cache_read" => 1.0, "cache_write" => 12.5}},
          {272_001, ".long_context",
           %{"input" => 20.0, "output" => 75.0, "cache_read" => 2.0, "cache_write" => 25.0}}
        ] do
      selection =
        Pricing.components_for(model,
          input_tokens: input_tokens,
          api: "responses",
          service_tier: "default"
        )

      assert selection.unresolved == []
      assert length(selection.components) == 4

      for component <- selection.components do
        meter =
          component.id |> String.replace_prefix("token.", "") |> String.replace_suffix(suffix, "")

        assert component.id == "token." <> meter <> suffix
        assert component.rate == Map.fetch!(expected_rates, meter)
        assert component.per == 1_000_000
        assert component.mode == "standard"
        assert component.charge_scope == "full_request"
        assert component.source == "provider_docs"
      end
    end
  end

  test "Astra extra metadata preserves mode multipliers without rate-less components" do
    model = astra_model()

    assert model.extra.pricing.mode_multipliers ==
             %{batch: 0.5, flex: 0.5, fast: 2.0, priority: 2.0}

    assert model.extra.pricing.mode_multiplier_scope =~ "both short and long context"
    assert model.extra.pricing.fast_mode_unavailable_data_residency == ["eu"]
    assert Enum.all?(model.pricing.components, &is_number(&1.rate))
  end

  test "packaged Astra metadata preserves limited access and the Responses contract" do
    model = Packaged.snapshot()["providers"]["openai"]["models"]["gpt-6-astra"]

    assert is_map(model)
    assert model["extra"]["availability"] == "limited"
    assert model["limits"] == %{"context" => 1_050_000, "input" => 922_000, "output" => 128_000}
    assert model["aliases"] == []
    assert length(model["pricing"]["components"]) == 8
    assert model["extra"]["pricing"]["mode_multipliers"]["fast"] == 2.0

    for operation <- ["text", "object"] do
      assert model["execution"][operation]["family"] == "openai_responses_compatible"
      assert model["execution"][operation]["wire_protocol"] == "openai_responses"
      assert model["execution"][operation]["path"] == "/responses"
    end
  end

  defp astra_model do
    {:ok, data} = Local.load(%{dir: @local_dir})

    data["openai"].models
    |> Normalize.normalize_models()
    |> Enum.find(&(&1.id == "gpt-6-astra"))
    |> Model.new!()
  end
end
