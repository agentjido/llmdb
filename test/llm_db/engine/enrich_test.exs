defmodule LLMDB.Engine.EnrichTest do
  use ExUnit.Case, async: true

  alias LLMDB.Enrich
  alias LLMDB.Test.Fixtures

  doctest LLMDB.Enrich

  test "reviewed unpublished limits cannot retain values from another source" do
    model = %{
      id: "unpublished-output",
      provider: :meta,
      limits: %{context: 1_048_576, input: 1_048_576, output: 131_072},
      extra: %{unpublished_limits: ["output"]},
      cost: %{input: 4.0}
    }

    [enriched] = Enrich.enrich_models([model])
    assert enriched.limits == %{context: 1_048_576, input: 1_048_576}
    assert enriched.cost == model.cost
  end

  @llmfit_url "https://raw.githubusercontent.com/AlexsJones/llmfit/main/llmfit-core/data/hf_models.json"

  defp llmfit_cache_path(url) do
    hash = :crypto.hash(:sha256, url) |> Base.encode16(case: :lower) |> binary_part(0, 8)
    "tmp/test/upstream/llmfit-#{hash}.json"
  end

  defp write_llmfit_cache(rows, url \\ @llmfit_url) do
    path = llmfit_cache_path(url)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(rows))
    path
  end

  describe "derive_family/1" do
    test "derives family from gpt-* models" do
      assert Enrich.derive_family("gpt-4o-mini") == "gpt-4o"
      assert Enrich.derive_family("gpt-4o") == "gpt"
      assert Enrich.derive_family("gpt-4-turbo") == "gpt-4"
      assert Enrich.derive_family("gpt-3.5-turbo") == "gpt-3.5"
    end

    test "derives family from claude-* models" do
      assert Enrich.derive_family("claude-3-opus") == "claude-3"
      assert Enrich.derive_family("claude-3-sonnet") == "claude-3"
      assert Enrich.derive_family("claude-3-haiku") == "claude-3"
      assert Enrich.derive_family("claude-3.5-sonnet") == "claude-3.5"
    end

    test "derives family from gemini-* models" do
      assert Enrich.derive_family("gemini-1.5-pro") == "gemini-1.5"
      assert Enrich.derive_family("gemini-1.5-flash") == "gemini-1.5"
      assert Enrich.derive_family("gemini-pro") == "gemini"
    end

    test "derives family from llama-* models" do
      assert Enrich.derive_family("llama-3.1-70b") == "llama-3.1"
      assert Enrich.derive_family("llama-3-8b") == "llama-3"
      assert Enrich.derive_family("llama-2-13b-chat") == "llama-2-13b"
    end

    test "derives family from mistral-* models" do
      assert Enrich.derive_family("mistral-large-latest") == "mistral-large"
      assert Enrich.derive_family("mistral-small") == "mistral"
    end

    test "handles single segment names" do
      assert Enrich.derive_family("gpt4") == nil
      assert Enrich.derive_family("claude") == nil
      assert Enrich.derive_family("model") == nil
    end

    test "handles two segment names" do
      assert Enrich.derive_family("two-parts") == "two"
      assert Enrich.derive_family("model-name") == "model"
    end

    test "handles complex multi-segment names" do
      assert Enrich.derive_family("provider-family-version-variant-size") ==
               "provider-family-version-variant"

      assert Enrich.derive_family("a-b-c-d-e") == "a-b-c-d"
    end

    test "handles version numbers with dots" do
      assert Enrich.derive_family("model-1.5-pro") == "model-1.5"
      assert Enrich.derive_family("model-v2.1-turbo") == "model-v2.1"
    end

    test "handles date-based suffixes" do
      assert Enrich.derive_family("gpt-4o-2024-08-06") == "gpt-4o-2024-08"
      assert Enrich.derive_family("model-20241101") == "model"
    end
  end

  describe "enrich_model/1" do
    test "adds family from ID when not present" do
      input = Fixtures.model_with_derivable_family()
      result = Enrich.enrich_model(input)

      assert result.id == input.id
      assert result.provider == input.provider
      assert result.family == Fixtures.expected_family_for_model(input.id)
    end

    test "preserves existing family" do
      input = Fixtures.model_with_existing_family()
      result = Enrich.enrich_model(input)

      assert result.family == "custom-family"
    end

    test "does not add family when cannot be derived" do
      input = Fixtures.model_single_segment()
      result = Enrich.enrich_model(input)

      assert result.id == input.id
      assert result.provider == input.provider
      refute Map.has_key?(result, :family)
    end

    test "adds provider_model_id from ID when not present" do
      input = Fixtures.model_with_derivable_family()
      result = Enrich.enrich_model(input)

      assert result.provider_model_id == input.id
    end

    test "preserves existing provider_model_id" do
      input = Fixtures.model_with_derivable_family(%{provider_model_id: "custom-provider-id"})
      result = Enrich.enrich_model(input)

      assert result.provider_model_id == "custom-provider-id"
    end

    test "enriches both fields when both missing" do
      input = Fixtures.model_with_derivable_family(%{id: "test-v3-advanced"})
      result = Enrich.enrich_model(input)

      assert result.id == "test-v3-advanced"
      assert result.provider == input.provider
      assert result.family == "test-v3"
      assert result.provider_model_id == "test-v3-advanced"
    end

    test "preserves all existing fields" do
      input = Fixtures.model_complete()
      result = Enrich.enrich_model(input)

      assert result.id == input.id
      assert result.provider == input.provider
      assert result.name == input.name
      assert result.release_date == input.release_date
      assert result.limits == input.limits
      assert result.cost == input.cost
      assert result.capabilities == input.capabilities
      assert result.tags == input.tags
      assert result.deprecated == input.deprecated
      assert result.aliases == input.aliases
      assert result.extra == input.extra
      assert result.family == Fixtures.expected_family_for_model(input.id)
      assert result.provider_model_id == input.id
    end

    test "handles models with single segment IDs" do
      input = Fixtures.model_single_segment(%{provider_model_id: "custom-id"})
      result = Enrich.enrich_model(input)

      assert result.id == input.id
      assert result.provider == input.provider
      assert result.provider_model_id == "custom-id"
      refute Map.has_key?(result, :family)
    end
  end

  describe "enrich_models/1" do
    test "enriches empty list" do
      assert Enrich.enrich_models([]) == []
    end

    test "enriches single model" do
      models = [Fixtures.model_with_derivable_family(%{id: "test-v1"})]
      result = Enrich.enrich_models(models)

      assert length(result) == 1
      assert hd(result).id == "test-v1"
      assert hd(result).family == "test"
      assert hd(result).provider_model_id == "test-v1"
    end

    test "enriches multiple models" do
      models = Fixtures.models_for_enrichment()
      result = Enrich.enrich_models(models)

      assert length(result) == 3
      assert Enum.at(result, 0).family == "test-model-v1"
      assert Enum.at(result, 1).family == "test-model-v2"
      assert Enum.at(result, 2).family == "test-model-v3"
    end

    test "preserves order of models" do
      models = [
        %{id: "first-model", provider: :test_provider_alpha},
        %{id: "second-model", provider: :test_provider_beta},
        %{id: "third-model", provider: :test_provider_gamma}
      ]

      result = Enrich.enrich_models(models)

      assert Enum.map(result, & &1.id) == ["first-model", "second-model", "third-model"]
    end

    test "enriches models with mixed completeness" do
      models = Fixtures.models_mixed_enrichment()
      result = Enrich.enrich_models(models)

      assert Enum.at(result, 0).family == "test-model"
      assert Enum.at(result, 0).provider_model_id == "test-model-v1"

      assert Enum.at(result, 1).family == "custom"
      assert Enum.at(result, 1).provider_model_id == "test-model-v2-pro"

      assert Enum.at(result, 2).family == "test-model-v3"
      assert Enum.at(result, 2).provider_model_id == "test-model-v3-flash-002"
    end

    test "handles models where family cannot be derived" do
      models = Fixtures.models_no_derivable_family()
      result = Enrich.enrich_models(models)

      assert length(result) == 2
      refute Map.has_key?(Enum.at(result, 0), :family)
      refute Map.has_key?(Enum.at(result, 1), :family)
      assert Enum.at(result, 0).provider_model_id == "model"
      assert Enum.at(result, 1).provider_model_id == "another"
    end
  end

  describe "inherit_canonical_costs/1" do
    test "dated model inherits cost from canonical" do
      models = [
        %{id: "gpt-4o-mini", provider: :openai, cost: %{input: 0.15, output: 0.6}},
        %{id: "gpt-4o-mini-2024-07-18", provider: :openai}
      ]

      [_canonical, dated] = Enrich.inherit_canonical_costs(models)
      assert dated.cost == %{input: 0.15, output: 0.6}
    end

    test "does not overwrite existing cost on dated model" do
      models = [
        %{id: "gpt-4o", provider: :openai, cost: %{input: 2.5, output: 10}},
        %{id: "gpt-4o-2024-08-06", provider: :openai, cost: %{input: 1.25, output: 5}}
      ]

      [_canonical, dated] = Enrich.inherit_canonical_costs(models)
      assert dated.cost == %{input: 1.25, output: 5}
    end

    test "does not inherit across providers" do
      models = [
        %{id: "model-v1", provider: :openai, cost: %{input: 1.0, output: 2.0}},
        %{id: "model-v1-2024-07-18", provider: :anthropic}
      ]

      [_canonical, dated] = Enrich.inherit_canonical_costs(models)
      refute Map.has_key?(dated, :cost)
    end

    test "leaves dated model unchanged when no canonical exists" do
      models = [
        %{id: "orphan-model-2024-07-18", provider: :openai}
      ]

      [dated] = Enrich.inherit_canonical_costs(models)
      refute Map.has_key?(dated, :cost)
    end

    test "leaves dated model unchanged when canonical has no cost" do
      models = [
        %{id: "gpt-4o-mini", provider: :openai},
        %{id: "gpt-4o-mini-2024-07-18", provider: :openai}
      ]

      [_canonical, dated] = Enrich.inherit_canonical_costs(models)
      refute Map.has_key?(dated, :cost)
    end

    test "handles multiple dated variants of the same canonical" do
      cost = %{input: 0.15, output: 0.6}

      models = [
        %{id: "gpt-4o-mini", provider: :openai, cost: cost},
        %{id: "gpt-4o-mini-2024-07-18", provider: :openai},
        %{id: "gpt-4o-mini-2025-01-15", provider: :openai}
      ]

      [_canonical, dated1, dated2] = Enrich.inherit_canonical_costs(models)
      assert dated1.cost == cost
      assert dated2.cost == cost
    end

    test "handles complex model IDs with date suffix" do
      cost = %{input: 1.0, output: 4.0}

      models = [
        %{id: "gpt-4o-mini-realtime-preview", provider: :openai, cost: cost},
        %{id: "gpt-4o-mini-realtime-preview-2024-12-17", provider: :openai}
      ]

      [_canonical, dated] = Enrich.inherit_canonical_costs(models)
      assert dated.cost == cost
    end

    test "does not treat non-date suffixes as dated models" do
      models = [
        %{id: "gpt-3.5-turbo", provider: :openai, cost: %{input: 0.5, output: 1.5}},
        %{id: "gpt-3.5-turbo-0125", provider: :openai}
      ]

      [_canonical, model] = Enrich.inherit_canonical_costs(models)
      refute Map.has_key?(model, :cost)
    end

    test "empty list returns empty list" do
      assert Enrich.inherit_canonical_costs([]) == []
    end

    test "integrates with enrich_models pipeline" do
      models = [
        %{id: "test-model-v1", provider: :test_provider_alpha, cost: %{input: 1.0, output: 2.0}},
        %{id: "test-model-v1-2024-07-18", provider: :test_provider_alpha}
      ]

      [canonical, dated] = Enrich.enrich_models(models)
      assert canonical.provider_model_id == "test-model-v1"
      assert dated.cost == %{input: 1.0, output: 2.0}
      assert dated.provider_model_id == "test-model-v1-2024-07-18"
    end
  end

  describe "llmfit enrichment" do
    setup do
      original_cache_dir = Application.get_env(:llm_db, :llmfit_cache_dir)
      original_enabled = Application.get_env(:llm_db, :llmfit_enrichment)

      File.rm_rf!("tmp/test/upstream")
      Application.put_env(:llm_db, :llmfit_cache_dir, "tmp/test/upstream")
      Application.put_env(:llm_db, :llmfit_enrichment, true)

      on_exit(fn ->
        File.rm_rf!("tmp/test/upstream")

        if is_nil(original_cache_dir) do
          Application.delete_env(:llm_db, :llmfit_cache_dir)
        else
          Application.put_env(:llm_db, :llmfit_cache_dir, original_cache_dir)
        end

        if is_nil(original_enabled) do
          Application.delete_env(:llm_db, :llmfit_enrichment)
        else
          Application.put_env(:llm_db, :llmfit_enrichment, original_enabled)
        end
      end)

      :ok
    end

    test "enriches models matched by extra.hugging_face_id" do
      write_llmfit_cache([
        %{
          "name" => "Qwen/Qwen2.5-7B-Instruct",
          "provider" => "Alibaba",
          "parameter_count" => "7.6B",
          "parameters_raw" => 7_600_000_000,
          "context_length" => 32_768,
          "pipeline_tag" => "text-generation",
          "min_ram_gb" => 8.1,
          "recommended_ram_gb" => 13.2,
          "min_vram_gb" => 7.0,
          "release_date" => "2024-09-01",
          "hf_downloads" => 1_000_000
        }
      ])

      models = [
        %{
          id: "openrouter/qwen2.5-7b",
          provider: :openrouter,
          extra: %{hugging_face_id: "Qwen/Qwen2.5-7B-Instruct"}
        }
      ]

      [model] = Enrich.enrich_models(models)
      assert model.release_date == "2024-09-01"
      assert model.limits.context == 32_768
      assert model.extra.llmfit.parameters_raw == 7_600_000_000
      assert model.extra.llmfit.memory.min_ram_gb == 8.1
      assert model.extra.llmfit.matched_hugging_face_id == "Qwen/Qwen2.5-7B-Instruct"
    end

    test "does not overwrite existing release_date or limits.context" do
      write_llmfit_cache([
        %{
          "name" => "Qwen/Qwen2.5-7B-Instruct",
          "provider" => "Alibaba",
          "parameter_count" => "7.6B",
          "parameters_raw" => 7_600_000_000,
          "context_length" => 32_768,
          "pipeline_tag" => "text-generation",
          "release_date" => "2024-09-01"
        }
      ])

      models = [
        %{
          id: "openrouter/qwen2.5-7b",
          provider: :openrouter,
          release_date: "2025-01-01",
          limits: %{context: 131_072},
          extra: %{hugging_face_id: "Qwen/Qwen2.5-7B-Instruct"}
        }
      ]

      [model] = Enrich.enrich_models(models)
      assert model.release_date == "2025-01-01"
      assert model.limits.context == 131_072
      assert model.extra.llmfit.parameters_raw == 7_600_000_000
    end

    test "matches by model id when hugging_face_id is absent" do
      write_llmfit_cache([
        %{
          "name" => "deepseek-ai/DeepSeek-V3",
          "provider" => "DeepSeek",
          "parameter_count" => "685B",
          "parameters_raw" => 685_000_000_000,
          "context_length" => 131_072,
          "pipeline_tag" => "text-generation"
        }
      ])

      models = [
        %{
          id: "deepseek-ai/DeepSeek-V3",
          provider: :huggingface
        }
      ]

      [model] = Enrich.enrich_models(models)
      assert model.extra.llmfit.model_id == "deepseek-ai/DeepSeek-V3"
      assert model.limits.context == 131_072
    end

    test "matches llmfit metadata for validated model structs" do
      write_llmfit_cache([
        %{
          "name" => "BAAI/bge-en-icl",
          "provider" => "BAAI",
          "parameter_count" => "7B",
          "parameters_raw" => 7_000_000_000,
          "context_length" => 32_768,
          "pipeline_tag" => "feature-extraction"
        }
      ])

      models = [
        %LLMDB.Model{
          id: "BAAI/bge-en-icl",
          name: "BGE-ICL",
          provider: :nebius,
          extra: %{family: "text-embedding"}
        }
      ]

      [model] = Enrich.enrich_models(models)
      assert model.extra.llmfit.model_id == "BAAI/bge-en-icl"
      assert model.limits.context == 32_768
    end

    test "skips llmfit metadata when enrichment is disabled" do
      Application.put_env(:llm_db, :llmfit_enrichment, false)

      write_llmfit_cache([
        %{
          "name" => "deepseek-ai/DeepSeek-V3",
          "provider" => "DeepSeek",
          "parameter_count" => "685B",
          "parameters_raw" => 685_000_000_000,
          "context_length" => 131_072,
          "pipeline_tag" => "text-generation"
        }
      ])

      models = [
        %{
          id: "deepseek-ai/DeepSeek-V3",
          provider: :huggingface
        }
      ]

      [model] = Enrich.enrich_models(models)
      refute get_in(model, [:extra, :llmfit])
      refute get_in(model, [:limits, :context])
    end
  end

  describe "integration with validation" do
    test "enrichment works before validation" do
      alias LLMDB.Validate

      raw_model = Fixtures.model_with_derivable_family(%{id: "test-model-v2-mini"})

      enriched = Enrich.enrich_model(raw_model)
      assert {:ok, validated} = Validate.validate_model(enriched)

      assert validated.id == "test-model-v2-mini"
      assert validated.provider == :test_provider_alpha
      assert validated.family == "test-model-v2"
      assert validated.provider_model_id == "test-model-v2-mini"
      assert validated.deprecated == false
      assert validated.aliases == []
    end

    test "batch enrichment works before batch validation" do
      alias LLMDB.Validate

      raw_models = [
        %{id: "test-model-v1", provider: :test_provider_alpha},
        %{id: "test-model-v2-pro", provider: :test_provider_beta},
        %{id: "invalid", provider: "string-not-atom"}
      ]

      enriched = Enrich.enrich_models(raw_models)
      assert {:ok, valid, 1} = Validate.validate_models(enriched)

      assert length(valid) == 2
      assert Enum.at(valid, 0).family == "test-model"
      assert Enum.at(valid, 1).family == "test-model-v2"
    end

    test "enrichment preserves complex nested structures for validation" do
      alias LLMDB.Validate

      raw_model = %{
        id: "test-model-v2-advanced",
        provider: :test_provider_alpha,
        limits: %{context: 128_000, output: 16_384},
        cost: %{input: 0.15, output: 0.60},
        capabilities: %{
          chat: true,
          tools: %{enabled: true, streaming: true}
        },
        modalities: %{
          input: [:text, :image],
          output: [:text]
        }
      }

      enriched = Enrich.enrich_model(raw_model)
      assert {:ok, validated} = Validate.validate_model(enriched)

      assert validated.family == "test-model-v2"
      assert validated.limits.context == 128_000
      assert validated.cost.input == 0.15
      assert validated.capabilities.chat == true
      assert validated.capabilities.tools.enabled == true
      assert validated.modalities.input == [:text, :image]
    end
  end

  describe "real-world model naming patterns" do
    test "handles OpenAI model names" do
      assert Enrich.derive_family("gpt-4o") == "gpt"
      assert Enrich.derive_family("gpt-4o-mini") == "gpt-4o"
      assert Enrich.derive_family("gpt-4-turbo") == "gpt-4"
      assert Enrich.derive_family("gpt-4-turbo-preview") == "gpt-4-turbo"
      assert Enrich.derive_family("gpt-3.5-turbo") == "gpt-3.5"
      assert Enrich.derive_family("gpt-3.5-turbo-0125") == "gpt-3.5-turbo"
    end

    test "handles Anthropic model names" do
      assert Enrich.derive_family("claude-3-opus-20240229") == "claude-3-opus"
      assert Enrich.derive_family("claude-3-sonnet-20240229") == "claude-3-sonnet"
      assert Enrich.derive_family("claude-3-haiku-20240307") == "claude-3-haiku"
      assert Enrich.derive_family("claude-3.5-sonnet-20241022") == "claude-3.5-sonnet"
    end

    test "handles Google model names" do
      assert Enrich.derive_family("gemini-1.5-pro") == "gemini-1.5"
      assert Enrich.derive_family("gemini-1.5-pro-002") == "gemini-1.5-pro"
      assert Enrich.derive_family("gemini-1.5-flash") == "gemini-1.5"
      assert Enrich.derive_family("gemini-pro") == "gemini"
      assert Enrich.derive_family("gemini-pro-vision") == "gemini-pro"
    end

    test "handles Meta Llama model names" do
      assert Enrich.derive_family("llama-3.1-405b-instruct") == "llama-3.1-405b"
      assert Enrich.derive_family("llama-3.1-70b-instruct") == "llama-3.1-70b"
      assert Enrich.derive_family("llama-3.1-8b-instruct") == "llama-3.1-8b"
      assert Enrich.derive_family("llama-3-70b-instruct") == "llama-3-70b"
    end

    test "handles Mistral model names" do
      assert Enrich.derive_family("mistral-large-latest") == "mistral-large"
      assert Enrich.derive_family("mistral-large-2411") == "mistral-large"
      assert Enrich.derive_family("mistral-small-latest") == "mistral-small"
      assert Enrich.derive_family("mistral-tiny") == "mistral"
    end

    test "handles Cohere model names" do
      assert Enrich.derive_family("command-r-plus") == "command-r"
      assert Enrich.derive_family("command-r") == "command"
      assert Enrich.derive_family("command-light") == "command"
    end

    test "handles embedding model names" do
      assert Enrich.derive_family("text-embedding-3-small") == "text-embedding-3"
      assert Enrich.derive_family("text-embedding-3-large") == "text-embedding-3"
      assert Enrich.derive_family("text-embedding-ada-002") == "text-embedding-ada"
    end
  end

  describe "inherit_hosted_claude_reasoning/1" do
    defp native_sonnet do
      %{
        id: "claude-sonnet-5-5",
        provider: :anthropic,
        capabilities: %{
          reasoning: %{
            enabled: true,
            effort: %{supported: true, values: ["low", "medium", "high", "xhigh", "max"]},
            thinking: %{
              supported: true,
              types: ["adaptive", "between_tools"],
              default_type: "adaptive",
              disable_supported: true
            }
          }
        },
        extra: %{
          thinking_constraints: %{
            "between_tools" => %{"effort_values" => ["low", "medium", "high"]}
          }
        }
      }
    end

    defp hosted(provider, id, extra \\ %{}) do
      %{
        id: id,
        provider: provider,
        capabilities: %{reasoning: %{enabled: true}},
        extra: Map.merge(%{canonical_model_id: "anthropic/claude-sonnet-5-5"}, extra)
      }
    end

    test "Bedrock, Vertex AI and Azure entries inherit native thinking, effort and constraints" do
      for model <- [
            hosted(:amazon_bedrock, "global.anthropic.claude-sonnet-5-5"),
            hosted(:google_vertex, "claude-sonnet-5-5@default"),
            hosted(:google_vertex_anthropic, "claude-sonnet-5-5@default"),
            hosted(:azure, "claude-sonnet-5-5", %{wire_protocol: "anthropic_messages"})
          ] do
        [_native, enriched] = Enrich.inherit_hosted_claude_reasoning([native_sonnet(), model])
        reasoning = enriched.capabilities.reasoning

        assert reasoning.enabled
        assert reasoning.thinking.types == ["adaptive", "between_tools"]
        assert reasoning.effort.values == ["low", "medium", "high", "xhigh", "max"]

        assert enriched.extra.thinking_constraints ==
                 native_sonnet().extra.thinking_constraints

        assert enriched.extra.canonical_model_id == "anthropic/claude-sonnet-5-5"
      end
    end

    test "values the hosted entry already sets are kept" do
      model =
        :amazon_bedrock
        |> hosted("us.anthropic.claude-sonnet-5-5")
        |> put_in(
          [:capabilities, :reasoning, :effort],
          %{supported: true, values: ["low", "medium", "high"]}
        )

      [_native, enriched] = Enrich.inherit_hosted_claude_reasoning([native_sonnet(), model])

      assert enriched.capabilities.reasoning.effort.values == ["low", "medium", "high"]
      assert enriched.capabilities.reasoning.thinking.types == ["adaptive", "between_tools"]
    end

    test "routers with their own request format are not changed" do
      model = hosted(:openrouter, "anthropic/claude-sonnet-5.5")
      azure_openai = hosted(:azure, "claude-sonnet-5-5", %{wire_protocol: "openai_responses"})

      assert [_native, ^model, ^azure_openai] =
               Enrich.inherit_hosted_claude_reasoning([native_sonnet(), model, azure_openai])
    end

    test "entries with reasoning disabled, no canonical link or a non-Anthropic link are not changed" do
      disabled =
        :amazon_bedrock
        |> hosted("us.anthropic.claude-sonnet-5-5")
        |> put_in([:capabilities, :reasoning, :enabled], false)

      unlinked = %{
        id: "anthropic.claude-sonnet-5-5",
        provider: :amazon_bedrock,
        capabilities: %{reasoning: %{enabled: true}}
      }

      other_link =
        hosted(:amazon_bedrock, "deepseek.v4", %{canonical_model_id: "deepseek/deepseek-v4"})

      models = [native_sonnet(), disabled, unlinked, other_link]
      assert Enrich.inherit_hosted_claude_reasoning(models) == models
    end
  end
end
