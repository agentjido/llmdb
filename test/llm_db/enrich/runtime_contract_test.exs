defmodule LLMDB.Enrich.RuntimeContractTest do
  use ExUnit.Case, async: true

  alias LLMDB.Enrich.RuntimeContract
  alias LLMDB.Sources.Local
  alias LLMDB.{Model, Provider}

  describe "enrich_provider/1" do
    test "adds typed runtime defaults for executable providers" do
      enriched = local_provider(:openai)

      assert enriched.catalog_only == false
      assert enriched.runtime.base_url == "https://api.openai.com/v1"
      assert enriched.runtime.auth.type == "bearer"
      assert enriched.runtime.auth.env == ["OPENAI_API_KEY"]
      assert enriched.runtime.doc_url == "https://platform.openai.com/docs"
    end

    test "adds config schema for providers with required runtime placeholders" do
      enriched = local_provider(:cloudflare_workers_ai)

      assert enriched.catalog_only == false

      assert enriched.runtime.base_url ==
               "https://api.cloudflare.com/client/v4/accounts/{account_id}/ai/v1"

      assert enriched.runtime.auth.type == "bearer"
      assert enriched.runtime.auth.env == ["CLOUDFLARE_API_KEY"]
      assert [%{name: "account_id", required: true}] = enriched.runtime.config_schema
    end

    test "adds native MiniMax runtime defaults" do
      enriched = local_provider(:minimax)

      assert enriched.catalog_only == false
      assert enriched.runtime.base_url == "https://api.minimax.io/v1"
      assert enriched.runtime.auth.type == "bearer"
      assert enriched.runtime.auth.env == ["MINIMAX_API_KEY"]
    end

    test "marks unsupported providers catalog only" do
      provider = Provider.new!(%{id: :docs_only_provider})
      enriched = RuntimeContract.enrich_provider(provider)

      assert enriched.catalog_only == true
      assert enriched.runtime == nil
    end

    test "preserves incomplete authored runtime metadata so validation can fail loudly" do
      provider =
        Provider.new!(%{
          id: :custom_provider,
          runtime: %{auth: %{type: :bearer, env: ["CUSTOM_API_KEY"]}}
        })

      enriched = RuntimeContract.enrich_provider(provider)

      assert enriched.catalog_only == false
      assert enriched.runtime.auth.type == "bearer"
      assert enriched.runtime.base_url == nil
    end
  end

  describe "enrich_model/2" do
    test "derives responses-family execution from explicit wire protocol" do
      provider = local_provider(:openai)

      model =
        Model.new!(%{
          id: "gpt-4.1",
          provider: :openai,
          extra: %{wire: %{protocol: "openai_responses"}}
        })

      enriched = RuntimeContract.enrich_model(model, provider)

      assert enriched.catalog_only == false
      assert enriched.execution.text.family == "openai_responses_compatible"
      assert enriched.execution.object.family == "openai_responses_compatible"
      assert enriched.execution.text.path == "/responses"
    end

    test "does not derive object execution for Anthropic models without JSON schema support" do
      provider = local_provider(:anthropic)

      model =
        Model.new!(%{
          id: "claude-opus-4-20250514",
          provider: :anthropic,
          capabilities: %{chat: true, json: %{schema: false, native: false, strict: false}},
          modalities: %{input: [:text], output: [:text]}
        })

      enriched = RuntimeContract.enrich_model(model, provider)

      assert enriched.catalog_only == false
      assert enriched.execution.text.family == "anthropic_messages"
      refute Map.has_key?(enriched.execution, :object)
    end

    test "derives object execution for Anthropic models with JSON schema support" do
      provider = local_provider(:anthropic)

      model =
        Model.new!(%{
          id: "claude-sonnet-4-5-20250929",
          provider: :anthropic,
          capabilities: %{chat: true, json: %{schema: true}},
          modalities: %{input: [:text], output: [:text]}
        })

      enriched = RuntimeContract.enrich_model(model, provider)

      assert enriched.catalog_only == false
      assert enriched.execution.text.family == "anthropic_messages"
      assert enriched.execution.object.family == "anthropic_messages"
    end

    test "derives speech execution for dedicated tts models without adding text operations" do
      provider = local_provider(:openai)

      model = Model.new!(%{id: "gpt-4o-mini-tts", provider: :openai})
      enriched = RuntimeContract.enrich_model(model, provider)

      assert enriched.catalog_only == false
      assert Map.has_key?(enriched.execution, :speech)
      refute Map.has_key?(enriched.execution, :text)
      refute Map.has_key?(enriched.execution, :object)
      assert enriched.execution.speech.family == "openai_speech"
    end

    test "keeps multimodal chat models on the text lane instead of misclassifying them as transcription" do
      provider = local_provider(:alibaba)

      model =
        Model.new!(%{
          id: "qwen3-omni-flash",
          provider: :alibaba,
          modalities: %{input: [:text, :image, :audio, :video], output: [:text, :audio]},
          capabilities: %{chat: true}
        })

      enriched = RuntimeContract.enrich_model(model, provider)

      assert enriched.catalog_only == false
      assert enriched.execution.text.family == "openai_chat_compatible"
      assert enriched.execution.object.family == "openai_chat_compatible"
      refute Map.has_key?(enriched.execution, :transcription)
    end

    test "marks models without a safe execution contract catalog only" do
      provider = local_provider(:google)

      model =
        Model.new!(%{
          id: "gemini-2.5-flash-image",
          provider: :google,
          modalities: %{input: [:text], output: [:image]}
        })

      enriched = RuntimeContract.enrich_model(model, provider)

      assert enriched.catalog_only == true
      assert enriched.execution == nil
    end

    test "derives Cohere-compatible rerank execution from explicit rerank source hints" do
      provider = local_provider(:cohere)

      model =
        Model.new!(%{
          id: "rerank-v3.5",
          provider: :cohere,
          extra: %{type: "rerank", supported_generation_methods: ["rerank"]}
        })

      enriched = RuntimeContract.enrich_model(model, provider)

      assert enriched.catalog_only == false
      assert enriched.execution.rerank.supported
      assert enriched.execution.rerank.family == "cohere_rerank_compatible"
      assert enriched.execution.rerank.wire_protocol == "cohere_rerank"
      assert enriched.execution.rerank.path == "/v2/rerank"
      assert enriched.capabilities.chat == false
      assert enriched.capabilities.rerank == true
      assert enriched.capabilities.streaming.text == false
    end

    test "derives embed execution for openrouter model with :embeddings plural in output modalities" do
      provider = local_provider(:openrouter)

      model =
        Model.new!(%{
          id: "baai/bge-m3",
          provider: :openrouter,
          modalities: %{input: [:text], output: [:embeddings]}
        })

      enriched = RuntimeContract.enrich_model(model, provider)

      assert enriched.catalog_only == false
      assert Map.has_key?(enriched.execution, :embed)
      assert enriched.execution.embed.family == "openai_embeddings"
      refute Map.has_key?(enriched.execution, :text)
      refute Map.has_key?(enriched.execution, :object)
    end

    test "derives embed execution for openrouter model with :embedding singular in output modalities" do
      provider = local_provider(:openrouter)

      model =
        Model.new!(%{
          id: "openai/text-embedding-ada-002",
          provider: :openrouter,
          modalities: %{input: [:text], output: [:embedding]}
        })

      enriched = RuntimeContract.enrich_model(model, provider)

      assert enriched.catalog_only == false
      assert Map.has_key?(enriched.execution, :embed)
      assert enriched.execution.embed.family == "openai_embeddings"
      refute Map.has_key?(enriched.execution, :text)
    end

    test "derives rerank capability metadata from reranker ids on catalog-only providers" do
      provider =
        Provider.new!(%{id: :berget})
        |> RuntimeContract.enrich_provider()

      model =
        Model.new!(%{
          id: "BAAI/bge-reranker-v2-m3",
          provider: :berget,
          name: "bge-reranker-v2-m3",
          modalities: %{input: [:text], output: [:text]}
        })

      enriched = RuntimeContract.enrich_model(model, provider)

      assert enriched.catalog_only == true
      assert enriched.capabilities.chat == false
      assert enriched.capabilities.rerank == true
    end
  end

  defp local_provider(id) do
    {:ok, providers} = Local.load(%{dir: "priv/llm_db/local"})

    providers
    |> Map.fetch!(Atom.to_string(id))
    |> Map.delete(:models)
    |> Map.put(:id, id)
    |> Provider.new!()
    |> RuntimeContract.enrich_provider()
  end
end
