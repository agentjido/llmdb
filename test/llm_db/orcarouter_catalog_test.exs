defmodule LLMDB.OrcaRouterCatalogTest do
  use ExUnit.Case, async: true

  alias LLMDB.Packaged
  alias LLMDB.Sources.Local

  test "packages OrcaRouter authentication without a provider-wide execution default" do
    provider = Packaged.snapshot()["providers"]["orcarouter"]

    refute provider["catalog_only"]
    assert provider["runtime"]["base_url"] == "https://api.orcarouter.ai/v1"
    assert provider["runtime"]["auth"]["type"] == "bearer"
    assert provider["runtime"]["auth"]["env"] == ["ORCAROUTER_API_KEY"]

    # Check the source too: publication removes provider execution defaults.
    {:ok, sources} = Local.load(%{dir: "priv/llm_db/local"})
    refute Map.has_key?(sources["orcarouter"].runtime, :execution)
  end

  test "packages the documented GPT-4o mini operations and capabilities" do
    model = Packaged.snapshot()["providers"]["orcarouter"]["models"]["openai/gpt-4o-mini"]

    assert model["id"] == "openai/gpt-4o-mini"
    assert model["provider"] == "orcarouter"
    assert (model["provider_model_id"] || model["id"]) == "openai/gpt-4o-mini"
    refute model["catalog_only"]
    assert Enum.sort(Map.keys(model["execution"])) == ["object", "text"]

    for operation <- ["text", "object"] do
      contract = model["execution"][operation]
      assert contract["supported"]
      assert contract["family"] == "openai_chat_compatible"
      assert contract["wire_protocol"] == "openai_chat"
      assert contract["transport"] == "http_request"
      assert contract["path"] == "/chat/completions"
      assert (contract["provider_model_id"] || model["id"]) == "openai/gpt-4o-mini"
    end

    capabilities = model["capabilities"]
    assert capabilities["streaming"]["text"]
    assert capabilities["tools"]["enabled"]
    assert capabilities["json"] == %{"native" => true, "schema" => true, "strict" => true}
    refute capabilities["streaming"]["tool_calls"]
    refute capabilities["tools"]["streaming"]
    refute capabilities["tools"]["strict"]
    refute capabilities["tools"]["parallel"]
  end

  test "all other imported entries remain catalog-only" do
    models = Packaged.snapshot()["providers"]["orcarouter"]["models"]

    # Cover routing aliases and an unverified chat model explicitly.
    for id <- ["orcarouter/auto", "orcarouter/fusion-mini", "anthropic/claude-haiku-4.5"] do
      assert Map.has_key?(models, id)
    end

    for {id, model} <- models, id != "openai/gpt-4o-mini" do
      assert model["catalog_only"] == true, "unexpected executable model: #{id}"

      for {_operation, contract} <- model["execution"] || %{} do
        refute contract["supported"], "unexpected execution contract: #{id}"
      end
    end
  end
end
