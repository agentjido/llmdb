defmodule LLMDB.TypeSafeCatalogTest do
  use ExUnit.Case, async: false

  setup do
    {:ok, _snapshot} = LLMDB.load()
    :ok
  end

  test "keeps moving Jev names as distinct executable model IDs" do
    assert {:ok, latest} = LLMDB.model("typesafe:jev-latest")
    assert {:ok, preview} = LLMDB.model("typesafe:jev-preview")
    assert {:ok, pinned} = LLMDB.model("typesafe:jev-1.13.0")

    assert latest.id == "jev-latest"
    assert preview.id == "jev-preview"
    assert pinned.id == "jev-1.13.0"
    assert latest.capabilities.evaluate
    refute latest.capabilities.chat
    assert latest.execution.evaluate.path == "/v1/systemone"

    assert Enum.sort(LLMDB.candidates(require: [evaluate: true], scope: :typesafe)) == [
             {:typesafe, "jev-1.13.0"},
             {:typesafe, "jev-latest"},
             {:typesafe, "jev-preview"}
           ]
  end
end
