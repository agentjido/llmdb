defmodule LLMDB.RequestyCatalogTest do
  use ExUnit.Case, async: false

  setup do
    {:ok, _snapshot} = LLMDB.load()
    :ok
  end

  test "packages Requesty with the OpenAI chat contract" do
    assert {:ok, provider} = LLMDB.provider(:requesty)
    refute provider.catalog_only
    assert provider.runtime.base_url == "https://router.requesty.ai/v1"
    assert provider.runtime.auth.type == "bearer"
    assert provider.runtime.auth.env == ["REQUESTY_API_KEY"]

    executable = Enum.reject(LLMDB.models(:requesty), & &1.catalog_only)
    assert executable != []

    for model <- executable do
      assert model.execution.text.family == "openai_chat_compatible"
      assert model.execution.text.path == "/chat/completions"
      refute Map.has_key?(model.execution, :object)
    end

    assert {:ok, model} = LLMDB.model("requesty:gpt-5.4-mini")
    refute model.catalog_only
    assert model.execution.text.supported
  end
end
