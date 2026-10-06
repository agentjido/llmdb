defmodule LLMDB.OpenAIDecisionsCatalogTest do
  use ExUnit.Case, async: false

  setup do
    {:ok, _snapshot} = LLMDB.load()
    :ok
  end

  test "lists only OpenAI models with Decisions evaluation support" do
    assert LLMDB.candidates(require: [evaluate: true], scope: :openai) == [
             {:openai, "gpt-6-luna"}
           ]

    assert {:ok, model} = LLMDB.model("openai:gpt-6-luna")
    assert model.execution.evaluate.family == "openai_decisions"
    assert model.execution.evaluate.path == "/decisions"
    assert model.execution.evaluate.provider_model_id == "gpt-6-luna"
  end
end
