defmodule LLMDB.A2AgentCatalogTest do
  use ExUnit.Case, async: false

  @model_ids ~w(
    deepseek-v4-flash deepseek-v4-pro
    glm-5 glm-5.1 glm-5.2 glm-5.3 glm-5.3-flash
    kimi-k2.5 kimi-k2.7-code kimi-k3
    minimax-m2.5 MiniMax-M2.7 minimax-m3
    qwen3.5-plus qwen3.6-flash qwen3.7-flash qwen3.7-max
    qwen3.7-plus qwen3.8-flash qwen3.8-max
  )

  setup do
    {:ok, _snapshot} = LLMDB.load()
    :ok
  end

  test "packages the public A2Agent catalog with the OpenAI chat contract" do
    assert {:ok, provider} = LLMDB.provider(:a2agent)
    assert provider.runtime.base_url == "https://api.a2agent.me/v1"
    assert provider.runtime.auth.type == "bearer"
    assert provider.runtime.auth.env == ["A2AGENT_API_KEY"]

    assert Enum.sort(LLMDB.candidates(scope: :a2agent)) ==
             Enum.sort(Enum.map(@model_ids, &{:a2agent, &1}))

    for id <- @model_ids do
      assert {:ok, model} = LLMDB.model({:a2agent, id})
      assert model.execution.text.family == "openai_chat_compatible"
      assert model.execution.text.path == "/chat/completions"
      refute Map.has_key?(model.execution, :object)
      refute Map.get(model.capabilities.streaming, :tool_calls)
      assert Map.get(model.limits, :output) == nil
    end

    assert {:ok, flash} = LLMDB.model("a2agent:qwen3.8-flash")
    assert flash.cost.input == 0.135
    assert flash.cost.output == 0.423

    assert {:ok, minimax} = LLMDB.model("a2agent:minimax-m3")
    assert minimax.modalities.input == [:text]
    assert minimax.capabilities.tools.enabled
  end
end
