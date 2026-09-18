defmodule LLMDB.JevGatewayCatalogTest do
  use ExUnit.Case, async: false

  setup do
    {:ok, _snapshot} = LLMDB.load()
    :ok
  end

  test "finds gateway Jev listings by evaluation capability" do
    assert Enum.sort(LLMDB.candidates(require: [evaluate: true], scope: :openrouter)) == [
             {:openrouter, "typesafe/jev-1.13"},
             {:openrouter, "~typesafe/jev-latest"}
           ]

    assert {:cloudflare_workers_ai, "typesafe/jev"} in LLMDB.candidates(
             require: [evaluate: true],
             scope: :cloudflare_workers_ai
           )

    assert {:vercel, "typesafe-ai/jev"} in LLMDB.candidates(
             require: [evaluate: true],
             scope: :vercel
           )
  end

  test "keeps the OpenRouter moving ID distinct from its pinned target" do
    assert {:ok, moving} = LLMDB.model("openrouter:~typesafe/jev-latest")
    assert {:ok, pinned} = LLMDB.model("openrouter:typesafe/jev-1.13")

    assert moving.id == "~typesafe/jev-latest"
    assert pinned.id == "typesafe/jev-1.13"
    assert moving.execution.evaluate.provider_model_id == moving.id
    assert pinned.execution.evaluate.provider_model_id == pinned.id
  end
end
