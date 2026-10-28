defmodule LLMDB.OpperRuntimeTest do
  use ExUnit.Case, async: true

  alias LLMDB.Enrich.RuntimeContract
  alias LLMDB.Sources.Local
  alias LLMDB.Provider

  test "declares Opper's OpenAI chat compatible runtime contract" do
    {:ok, providers} = Local.load(%{dir: "priv/llm_db/local"})

    provider =
      providers
      |> Map.fetch!("opper")
      |> Map.delete(:models)
      |> Map.put(:id, :opper)
      |> Provider.new!()
      |> RuntimeContract.enrich_provider()

    refute provider.catalog_only
    assert provider.runtime.base_url == "https://api.opper.ai/v3/compat"
    assert provider.runtime.auth.type == "bearer"
    assert provider.runtime.auth.env == ["OPPER_API_KEY"]
    assert provider.runtime.doc_url == "https://docs.opper.ai/build/gateway/drop-in-sdks"
  end
end
