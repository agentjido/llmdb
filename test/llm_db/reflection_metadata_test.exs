defmodule LLMDB.ReflectionMetadataTest do
  use ExUnit.Case, async: true

  alias LLMDB.{ExecutionContract, Model, Normalize, Packaged, Provider}
  alias LLMDB.Sources.Local

  @model_id "Beam-1.0-501B-A23B"

  setup_all do
    {:ok, data} = Local.load(%{dir: "priv/llm_db/local"})
    reflection = Map.fetch!(data, "reflection")

    provider =
      reflection
      |> Map.delete(:models)
      |> Map.put(:id, :reflection)
      |> Provider.new!()
      |> ExecutionContract.enrich_provider()

    [attrs] = Normalize.normalize_models(reflection.models)
    model = attrs |> Model.new!() |> ExecutionContract.enrich_model(provider)

    %{provider: provider, model: model}
  end

  test "provider uses bearer authentication and only chat execution", %{provider: provider} do
    assert provider.name == "Reflection AI"
    assert provider.base_url == "https://api.reflection.ai/openai/v1"
    assert provider.env == ["REFLECTION_API_KEY"]
    refute provider.catalog_only
    assert provider.runtime.base_url == provider.base_url
    assert provider.runtime.auth.type == "bearer"
    assert provider.runtime.auth.env == provider.env
    assert provider.runtime.execution.text == "openai_chat_compatible"
    assert provider.runtime.execution.object == "openai_chat_compatible"

    for operation <- [:embed, :image, :speech, :transcription, :realtime, :evaluate] do
      assert is_nil(provider.runtime.execution[operation])
    end
  end

  test "Beam uses the current model ID and hosted API limits", %{model: model} do
    assert model.id == @model_id
    assert model.provider_model_id == @model_id
    assert model.release_date == "2026-10-05"
    assert model.knowledge == "2026-06-30"
    assert model.limits == %{context: 262_144, output: 131_072}
    assert model.modalities == %{input: [:text], output: [:text]}
    assert model.extra.availability == "beta"
    assert model.extra.constraints.token_limit_key == "max_completion_tokens"
    assert model.extra.wire.protocol == "openai_chat"
    assert is_nil(model.cost)
    assert is_nil(model.pricing)
  end

  test "mandatory reasoning preserves organization-specific defaults", %{model: model} do
    assert model.capabilities.reasoning.enabled
    assert model.capabilities.reasoning.effort.supported
    assert model.capabilities.reasoning.effort.values == ["low", "medium", "high", "xhigh", "max"]
    assert is_nil(model.capabilities.reasoning.effort[:default])
    assert model.extra.reasoning.mandatory
    assert model.extra.reasoning.default_effort_scope == "organization"
    assert model.extra.interleaved.field == "reasoning_content"
    assert model.extra.constraints.reasoning_effort == "supported"
  end

  test "tools, JSON, and streaming use the Chat Completions contract", %{model: model} do
    assert model.capabilities.tools.enabled
    assert model.capabilities.tools.strict
    assert model.capabilities.tools.parallel
    assert model.capabilities.tools.streaming
    assert model.capabilities.json.native
    assert model.capabilities.json.schema
    assert model.capabilities.json.strict
    assert model.capabilities.streaming.text
    assert model.capabilities.streaming.tool_calls
    refute model.capabilities.embeddings
    refute model.catalog_only
    assert Enum.sort(Map.keys(model.execution)) == [:object, :text]

    for operation <- [:text, :object] do
      execution = model.execution[operation]
      assert execution.supported
      assert execution.family == "openai_chat_compatible"
      assert execution.wire_protocol == "openai_chat"
      assert execution.path == "/chat/completions"
    end
  end

  test "packaged catalog includes Reflection without prices or a global reasoning default" do
    provider = Packaged.snapshot()["providers"]["reflection"]
    assert is_map(provider)
    assert provider["runtime"]["auth"]["env"] == ["REFLECTION_API_KEY"]
    refute provider["catalog_only"]
    assert Map.keys(provider["models"]) == [@model_id]

    model = provider["models"][@model_id]
    assert model["limits"] == %{"context" => 262_144, "output" => 131_072}
    assert model["provider_model_id"] == @model_id
    assert model["extra"]["reasoning"]["mandatory"]
    assert is_nil(model["capabilities"]["reasoning"]["effort"]["default"])
    assert is_nil(model["cost"])
    assert is_nil(model["pricing"])
    assert Enum.sort(Map.keys(model["execution"])) == ["object", "text"]

    for operation <- ["text", "object"] do
      assert model["execution"][operation]["family"] == "openai_chat_compatible"
      assert model["execution"][operation]["wire_protocol"] == "openai_chat"
    end

    assert {:ok, :reflection} = LLMDB.Generated.ProviderRegistry.fetch("reflection")
  end
end
