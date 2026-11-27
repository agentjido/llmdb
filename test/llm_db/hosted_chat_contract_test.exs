defmodule LLMDB.HostedChatContractTest do
  use ExUnit.Case, async: true

  alias LLMDB.{ExecutionContract, Model, Pricing, Provider}
  alias LLMDB.Sources.Local

  setup_all do
    {:ok, sources} = Local.load(%{dir: "priv/llm_db/local"})
    %{sources: sources}
  end

  test "only reviewed models gain an executable text operation", %{sources: sources} do
    for {id, model_id} <- [
          baseten: "zai-org/GLM-5.3",
          deepinfra: "openai/gpt-oss-120b",
          huggingface: "openai/gpt-oss-120b",
          nebius: "openai/gpt-oss-120b",
          novita_ai: "openai/gpt-oss-120b",
          sambanova: "MiniMax-M3.1-Flash"
        ] do
      source = Map.fetch!(sources, to_string(id))

      provider =
        source
        |> Map.delete(:models)
        |> Map.put(:id, id)
        |> Provider.new!()
        |> ExecutionContract.enrich_provider()

      refute provider.catalog_only
      assert %{auth: %{type: "bearer", env: [_]}, base_url: "https://" <> _} = provider.runtime
      refute Map.has_key?(source.runtime, :execution)

      model =
        source.models
        |> Enum.find(&(&1.id == model_id))
        |> Model.new!()
        |> ExecutionContract.enrich_model(provider)

      refute model.catalog_only

      assert %{
               text: %{
                 family: "openai_chat_compatible",
                 path: "/chat/completions",
                 supported: true
               }
             } = model.execution

      assert Map.keys(model.execution) == [:text]

      unreviewed =
        Model.new!(%{id: "another-chat-model", provider: id, capabilities: %{chat: true}})

      assert ExecutionContract.enrich_model(unreviewed, provider).catalog_only
    end
  end

  test "the published Ollama Cloud prices require a pricing period for aliases and dated tags", %{
    sources: sources
  } do
    for {id, off_peak, peak} <- [
          {"deepseek-v4-pro", [0.66, 0.022, 1.98], [1.32, 0.044, 3.96]},
          {"deepseek-v4-pro:0813", [0.66, 0.022, 1.98], [1.32, 0.044, 3.96]},
          {"deepseek-v4.1-flash", [0.15, 0.003, 0.60], [0.30, 0.006, 1.20]},
          {"deepseek-v4.1-flash:1017", [0.15, 0.003, 0.60], [0.30, 0.006, 1.20]}
        ] do
      [input, cache, output] = off_peak

      [model] =
        sources["ollama_cloud"].models
        |> Enum.filter(&(&1.id == id))
        |> Enum.map(&Map.put(&1, :cost, %{input: input, cache_read: cache, output: output}))
        |> Enum.map(&Model.new!/1)
        |> Pricing.apply_cost_components()

      assert %{components: [], unresolved: unknown} = Pricing.components_for(model)
      assert length(unknown) == 6

      for {period, expected} <- [{"off_peak", off_peak}, {"peak", peak}] do
        assert %{unresolved: [], components: rates} =
                 Pricing.components_for(model, %{pricing_period: period})

        assert Map.new(rates, &{&1.meter, &1.rate}) ==
                 Map.new(Enum.zip(~w(input_tokens cache_read_tokens output_tokens), expected))
      end
    end
  end
end
