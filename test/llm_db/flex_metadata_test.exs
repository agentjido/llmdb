defmodule LLMDB.FlexMetadataTest do
  use ExUnit.Case, async: false

  alias LLMDB.{Catalog, Engine, Loader, Pricing}
  alias LLMDB.Enrich.Flex
  alias LLMDB.Snapshot.Builder
  alias LLMDB.Sources.Config

  test "cached Flex prices retain provider eligibility and model overrides" do
    route = %{"body" => %{"service_tier" => "flex"}}
    cost = %{"input" => 5, "output" => 25, "cache_read" => 0.5, "cache_write" => 6.25}
    cached_flex = %{"cost" => cost, "provider" => route}
    disabled_flex = %{"supported" => false}

    policy = %{
      "models" => ["priced", "disabled"],
      "supported" => true,
      "apis" => ["responses", "chat_completions"],
      "provider" => route
    }

    provider = %{id: :openai, extra: %{experimental: %{"modes" => %{"flex" => policy}}}}
    cached_extra = %{experimental: %{"modes" => %{"flex" => cached_flex}}}
    disabled_extra = %{experimental: %{"modes" => %{"flex" => disabled_flex}}}

    models = [
      %{id: "priced", provider: :openai, extra: cached_extra},
      %{id: "disabled", provider: :openai, extra: disabled_extra},
      %{id: "unlisted", provider: :openai, extra: cached_extra}
    ]

    assert [
             %{extra: %{experimental: %{"modes" => %{"flex" => priced_flex}}}},
             %{extra: ^disabled_extra},
             %{extra: ^cached_extra}
           ] = Flex.enrich_models([provider], models)

    assert %{
             "cost" => ^cost,
             "provider" => ^route,
             "supported" => true,
             "apis" => ["responses", "chat_completions"]
           } = priced_flex
  end

  test "cached Fast metadata and a local Flex opt-out survive layer merging" do
    fast = %{"cost" => %{"input" => 16, "output" => 80}}

    upstream = %{
      id: "gpt-6.2-astra",
      provider: :openai,
      extra: %{experimental: %{"modes" => %{"fast" => fast}}}
    }

    local = %{
      id: "gpt-6.2-astra",
      provider: :openai,
      extra: %{experimental: %{modes: %{flex: %{supported: false}}}}
    }

    sources = [
      {Config, %{overrides: %{providers: [%{id: :openai, name: "OpenAI"}], models: [upstream]}}},
      {Config, %{overrides: %{models: [local]}}}
    ]

    assert {:ok, snapshot} = Engine.run(sources: sources)

    assert snapshot.providers.openai.models["gpt-6.2-astra"].extra.experimental == %{
             "modes" => %{"fast" => fast, "flex" => %{"supported" => false}}
           }
  end

  @tag :tmp_dir
  test "Flex mappings and batch prices survive catalog build and lookup", %{tmp_dir: tmp_dir} do
    assert {:ok, artifact} = build_from_checked_in_sources(tmp_dir)
    %{snapshot_path: path} = Builder.write!(artifact)
    assert {:ok, catalog} = Loader.load(snapshot_source: {:file, path})

    assert_openai_flex(catalog)
    assert_bedrock_flex(catalog)
    assert_azure_and_groq_flex(catalog)
    assert_google_flex(catalog)
    assert_gateway_flex(catalog)
  end

  defp assert_openai_flex(catalog) do
    for id <- ~w(gpt-6-astra gpt-6-luna gpt-6-sol gpt-6.1-sol gpt-6.1-terra) do
      assert %{
               "supported" => true,
               "apis" => ["responses", "chat_completions"],
               "provider" => %{"body" => %{"service_tier" => "flex"}}
             } = flex(catalog, :openai, id)
    end

    for id <- ~w(gpt-6.2-astra gpt-6.2-sol) do
      model = model(catalog, :openai, id)
      assert %{"supported" => false} = flex(catalog, :openai, id)
      refute Map.has_key?(flex(catalog, :openai, id), "provider")
      assert model.extra["pricing"]["mode_multipliers"]["batch"] == 0.5
      refute Map.has_key?(model.extra["pricing"]["mode_multipliers"], "flex")
      refute Enum.any?(model.pricing.components, &match?(%{mode: "flex"}, &1))

      batch = Pricing.components_for(model, api: "batch", input_tokens: 1_000)
      assert Enum.any?(batch.components, &match?(%{id: "pricing.batch", multiplier: 0.5}, &1))
    end
  end

  defp assert_bedrock_flex(catalog) do
    for id <- ~w(amazon.nova-2-lite-v1:0 openai.gpt-oss-120b-1:0) do
      assert %{
               "supported" => true,
               "apis" => ["converse"],
               "provider" => %{"body" => %{"serviceTier" => %{"type" => "flex"}}}
             } = flex(catalog, :amazon_bedrock, id)
    end

    nova = flex(catalog, :amazon_bedrock, "amazon.nova-2-lite-v1:0")
    assert nova["constraints"]["inference_profile_required"]
    refute flex(catalog, :amazon_bedrock, "amazon.nova-lite-v1:0")
  end

  defp assert_azure_and_groq_flex(catalog) do
    assert %{
             "supported" => true,
             "provider" => %{"body" => %{"service_tier" => "flex"}},
             "constraints" => %{
               "deployment_type" => "Global Standard",
               "model_version" => "2026-07-09"
             }
           } = flex(catalog, :azure, "gpt-5.6-sol")

    refute flex(catalog, :azure, "gpt-6.1-terra")

    assert {:ok, provider} = Catalog.provider(catalog, :groq)
    assert provider.extra["experimental"]["modes"]["flex"]["models"] == "all"

    assert %{
             "supported" => true,
             "apis" => ["chat_completions"],
             "provider" => %{"body" => %{"service_tier" => "flex"}},
             "constraints" => %{"account" => "paid"}
           } = flex(catalog, :groq, "openai/gpt-oss-120b")
  end

  defp assert_google_flex(catalog) do
    assert %{
             "supported" => true,
             "apis" => ["interactions"],
             "provider" => %{"body" => %{"service_tier" => "flex"}}
           } = flex(catalog, :google, "gemini-4-neon")

    assert %{
             "supported" => true,
             "apis" => ["generate_content", "stream_generate_content"],
             "constraints" => %{
               "region" => "global",
               "endpoint" => "https://aiplatform.googleapis.com"
             },
             "provider" => %{
               "headers" => %{
                 "X-Vertex-AI-LLM-Request-Type" => "shared",
                 "X-Vertex-AI-LLM-Shared-Request-Type" => "flex"
               }
             }
           } = flex(catalog, :google_vertex, "gemini-3.8-flash")

    cyber = flex(catalog, :google_vertex, "gemini-3.8-flash-cyber")
    assert cyber["constraints"]["account"] == "allowlisted"
    refute flex(catalog, :google_vertex, "gemini-4-argon")
  end

  defp assert_gateway_flex(catalog) do
    assert %{"provider" => %{"body" => %{"service_tier" => "flex"}}} =
             flex(catalog, :vercel, "openai/gpt-5")

    assert %{"supported" => true, "provider" => %{"body" => %{"service_tier" => "flex"}}} =
             flex(catalog, :deepinfra, "deepseek-ai/DeepSeek-V4.1-Flash-1017")

    router_model = model(catalog, :openrouter, "openai/gpt-6.1-sol")
    modes = router_model.extra["experimental"]["modes"]

    for {mode, endpoint} <- [{"flex", "openai/flex"}, {"priority", "openai/fast"}] do
      assert %{
               "supported" => true,
               "constraints" => %{"endpoint" => "https://openrouter.ai/api/v1"},
               "provider" => %{"body" => %{"provider" => %{"only" => [^endpoint]}}}
             } = modes[mode]
    end

    assert %{
             "supported" => true,
             "provider" => %{
               "body" => %{
                 "provider" => %{"only" => ["particle-ai/us/flex", "deepinfra/fp8/flex"]}
               }
             }
           } = flex(catalog, :openrouter, "deepseek/deepseek-v4.1-flash-1017")
  end

  defp flex(catalog, provider, id) do
    model = model(catalog, provider, id)
    get_in(model.extra || %{}, ~w(experimental modes flex))
  end

  defp model(catalog, provider, id) do
    assert {:ok, {^provider, ^id, model}} = Catalog.resolve_model(catalog, provider, id)
    model
  end

  defp build_from_checked_in_sources(tmp_dir) do
    keys = [:models_dev_cache_dir, :openrouter_cache_dir]
    original_dirs = Map.new(keys, &{&1, Application.fetch_env!(:llm_db, &1)})

    for key <- keys do
      Application.put_env(:llm_db, key, "priv/llm_db/upstream")
    end

    try do
      Builder.build(output_dir: tmp_dir)
    after
      for {key, dir} <- original_dirs do
        Application.put_env(:llm_db, key, dir)
      end
    end
  end
end
