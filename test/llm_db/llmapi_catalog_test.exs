defmodule LLMDB.LLMAPICatalogTest do
  use ExUnit.Case, async: false

  alias LLMDB.Packaged
  alias LLMDB.Sources.{LLMAPI, Local}

  @initial_models ~w(
    gpt-4o-mini gpt-4.1-mini claude-haiku-4-5 claude-sonnet-4-6
    gemini-2.5-flash deepseek-v4-flash grok-4.3 qwen3-coder-plus
    llama-3.3-70b-instruct ministral-8b-2512
  )

  setup do
    {:ok, _catalog} = LLMDB.load()
    :ok
  end

  test "packages bearer authentication without enabling every catalog entry" do
    assert {:ok, provider} = LLMDB.provider(:llmapi)
    refute provider.catalog_only
    assert provider.runtime.base_url == "https://api.llmapi.ai/v1"
    assert provider.runtime.auth.type == "bearer"
    assert provider.runtime.auth.env == ["LLM_API_KEY", "LLMAPI_API_KEY"]
    assert provider.runtime.default_headers == %{}
    assert provider.runtime.default_query == %{}

    {:ok, local} = Local.load(%{dir: "priv/llm_db/local"})
    refute Map.has_key?(local["llmapi"].runtime, :execution)
  end

  test "distinct audio and image prices cannot use the legacy flat input rate" do
    for id <-
          ~w(gemini-2.5-flash gemini-2.5-flash-lite gemini-3-flash-preview gemini-3.1-flash-lite qwen/qwen3.8-omni-flash) do
      assert {:ok, model} = LLMDB.model({:llmapi, id})
      assert model.extra["pricing_input_split_required"]
      assert model.pricing.excluded_cost_components == ["token.input"]
      refute Enum.any?(model.pricing.components, &(&1.id == "token.input"))
      assert model.cost.input > 0
    end
  end

  test "retains every cached public model ID under the LLM API namespace" do
    {:ok, source} = LLMAPI.load(%{})
    models = Packaged.snapshot()["providers"]["llmapi"]["models"]
    assert source["llmapi"].models != []
    assert Enum.sort(Map.keys(models)) == Enum.sort(Enum.map(source["llmapi"].models, & &1.id))

    assert Enum.all?(models, fn {id, model} ->
             model["id"] == id and model["provider"] == "llmapi"
           end)
  end

  test "every cached one-hour tariff survives packaged loading with the correct duration" do
    raw = File.read!("priv/llm_db/remote/llmapi-5df41fd3.json") |> Jason.decode!()

    models =
      Enum.filter(
        raw["data"],
        &(&1["kind"] == "chat" and get_in(&1, ["pricing", "input_cache_write_1h"]) != nil)
      )

    assert length(models) == 11

    for source <- models do
      assert {:ok, model} = LLMDB.model({:llmapi, source["id"]})

      for {ttl, field} <- [{"5m", "input_cache_write"}, {"1h", "input_cache_write_1h"}] do
        selection = LLMDB.Pricing.components_for(model, cache_ttl: ttl)

        writes =
          Enum.filter(selection.components, &String.starts_with?(&1.id, "token.cache_write"))

        if price = source["pricing"][field] do
          {expected, ""} = Float.parse(price)
          assert [component] = writes
          assert_in_delta component.rate, expected * 1_000_000, 1.0e-9
        else
          assert writes == []
        end
      end
    end
  end

  test "reviewed chat models resolve exact wire IDs with text and tool-based object contracts" do
    for id <- @initial_models do
      assert {:ok, model} = LLMDB.model("llmapi:#{id}")
      assert model.provider == :llmapi
      assert model.id == id
      assert (model.provider_model_id || model.id) == id
      refute model.catalog_only
      assert model.capabilities.streaming.text
      assert model.capabilities.tools.enabled
      refute model.capabilities.tools.strict
      refute model.capabilities.tools.streaming
      refute model.capabilities.streaming.tool_calls
      assert model.limits[:output] == nil

      for operation <- [:text, :object] do
        contract = model.execution[operation]
        assert contract.supported
        assert contract.family == "openai_chat_compatible"
        assert contract.wire_protocol == "openai_chat"
        assert contract.path == "/chat/completions"
        assert contract[:transport] == nil
        assert (contract[:provider_model_id] || model.id) == id
      end
    end

    assert {:ok, model} = LLMDB.model("llmapi:gpt-4o-mini")
    assert model.cost.input == 0.15
    assert model.cost.output == 0.6
    assert model.cost.cache_read == 0.075

    assert {:ok, %{provider: :llmapi, id: "deepseek/deepseek-v4.1-flash"}} =
             LLMDB.model("llmapi:deepseek/deepseek-v4.1-flash")

    assert {:ok, %{provider: :llmapi, id: "claude-haiku-4-5"}} =
             LLMDB.model("llmapi:claude-haiku-4.5")
  end

  test "media, mixed-protocol and Responses-only models cannot execute through Chat" do
    for id <- ["amazon.titan-embed-text-v2:0", "gpt-5-pro", "gpt-5.6-sol"] do
      assert {:ok, model} = LLMDB.model({:llmapi, id})
      assert model.catalog_only
      assert model.execution == nil
    end

    for {id, output} <- [{"gpt-image-2.5-flare", :image}, {"ltx-2.3-t2v", :video}] do
      assert {:ok, model} = LLMDB.model({:llmapi, id})
      assert model.catalog_only
      refute model.capabilities.chat
      refute model.capabilities.streaming.text
      assert model.modalities.output == [output]
      assert model.execution == nil
    end

    assert {:ok, model} = LLMDB.model({:llmapi, "zaya1-8b"})
    refute model.catalog_only
    assert model.execution.text.supported
    assert model.cost == nil
    assert model.extra["free"] == true

    for id <- ~w(gpt-5 gpt-5-mini gpt-5-nano) do
      assert {:ok, model} = LLMDB.model({:llmapi, id})
      assert model.execution.text.supported
      refute Map.has_key?(model.execution, :object)
      refute "max_tokens" in model.extra["supported_parameters"]
    end

    assert {:ok, model} = LLMDB.model("llmapi:kimi-k2.5")
    assert model.modalities.input == [:text]
    assert model.extra["reported_modalities"]["input_modalities"] == ["text", "image"]
  end
end
