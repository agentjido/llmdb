defmodule LLMDB.UberLLMRuntimeTest do
  use ExUnit.Case, async: true

  alias LLMDB.Enrich.RuntimeContract
  alias LLMDB.Pricing
  alias LLMDB.Provider
  alias LLMDB.Sources.Local

  setup_all do
    {:ok, providers} = Local.load(%{dir: "priv/llm_db/local"})
    %{source: Map.fetch!(providers, "uberllm")}
  end

  test "declares UberLLM's OpenAI chat compatible runtime contract", %{source: source} do
    provider =
      source
      |> Map.delete(:models)
      |> Map.put(:id, :uberllm)
      |> Provider.new!()
      |> RuntimeContract.enrich_provider()

    refute provider.catalog_only
    assert provider.name == "UberLLM"
    assert provider.runtime.base_url == "https://api.uberllm.dev/v1"
    assert provider.runtime.auth.type == "bearer"
    assert provider.runtime.auth.env == ["UBERLLM_API_KEY"]
    assert provider.runtime.doc_url == "https://uberllm.dev/docs/quickstart"
  end

  test "ships the starter model IDs without fixed seller rates", %{source: source} do
    models = Map.new(source.models, &{&1.id, &1})

    assert Enum.sort(Map.keys(models)) == [
             "anthropic/claude-sonnet-5",
             "deepseek/deepseek-v4.1-flash",
             "openai/gpt-5.4-mini"
           ]

    for {id, model} <- models do
      assert model.provider == :uberllm
      assert model.provider_model_id == id
      assert Map.get(model, :cost) in [nil, %{}]
      assert Pricing.components_for(model) == %{components: [], unresolved: []}
      assert model.extra.wire.protocol == "openai_chat"
    end
  end
end
