defmodule LLMDB.AzureDecisionsCatalogTest do
  use ExUnit.Case, async: false

  setup do
    {:ok, _snapshot} = LLMDB.load()
    :ok
  end

  test "resolves the Foundry model name and discovers it for evaluation only" do
    assert {:ok, model} = LLMDB.model("azure:microsoft-decision-1")
    assert {:ok, ^model} = LLMDB.model("azure:Microsoft-Decision-1")

    assert {:azure, model.id} in LLMDB.candidates(require: [evaluate: true], scope: :azure)
    refute {:azure, model.id} in LLMDB.candidates(require: [chat: true], scope: :azure)

    assert model.modalities == %{input: [:text], output: [:decisions]}
    assert model.capabilities.streaming == %{text: false, tool_calls: false}

    assert Map.keys(model.execution) == [:evaluate]

    assert %{
             evaluate: %{
               supported: true,
               family: "typesafe_systemone",
               wire_protocol: "typesafe_systemone",
               provider_model_id: "Microsoft-Decision-1",
               path: "/providers/microsoft/v1/systemone"
             }
           } = model.execution
  end

  test "preserves the context limit and free output pricing in the packaged catalog" do
    assert {:ok, model} = LLMDB.model("azure:microsoft-decision-1")
    assert model.limits.context == 32_768
    assert model.cost.input == 0.042
    assert model.cost.output == 0.0

    rates = Map.new(model.pricing.components, &{&1.id, &1.rate})
    assert rates["token.input"] == 0.042
    assert rates["token.output"] == 0.0
  end
end
