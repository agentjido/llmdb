defmodule LLMDB.Schema.ModelTest do
  use ExUnit.Case, async: true

  alias LLMDB.Model

  describe "valid parsing" do
    test "parses minimal valid model" do
      input = %{
        id: "gpt-4o-mini",
        provider: :openai
      }

      assert {:ok, result} = Zoi.parse(Model.schema(), input)
      assert result.id == "gpt-4o-mini"
      assert result.provider == :openai
      assert result.deprecated == false
      assert result.aliases == []
    end

    test "parses complete model with all fields" do
      input = %{
        id: "gpt-4o-mini",
        provider: :openai,
        provider_model_id: "gpt-4o-mini-2024-07-18",
        name: "GPT-4o Mini",
        family: "gpt-4o",
        doc_url: "https://platform.openai.com/docs/models/gpt-4o-mini",
        release_date: "2024-07-18",
        last_updated: "2024-10-01",
        knowledge: "2023-10",
        limits: %{context: 128_000, output: 16_384},
        cost: %{input: 0.15, output: 0.60},
        modalities: %{
          input: [:text, :image],
          output: [:text]
        },
        capabilities: %{
          chat: true,
          tools: %{enabled: true, streaming: true}
        },
        execution: %{
          text: %{
            supported: true,
            family: "openai_chat_compatible",
            wire_protocol: "openai_chat",
            transport: "http_request",
            path: "/chat/completions"
          },
          object: %{
            supported: true,
            family: "openai_chat_compatible",
            wire_protocol: "openai_chat",
            transport: "http_request"
          }
        },
        tags: ["fast", "cheap"],
        deprecated: false,
        aliases: ["gpt-4o-mini-latest"],
        extra: %{"custom" => "value"}
      }

      assert {:ok, result} = Zoi.parse(Model.schema(), input)
      assert result.id == "gpt-4o-mini"
      assert result.provider == :openai
      assert result.provider_model_id == "gpt-4o-mini-2024-07-18"
      assert result.name == "GPT-4o Mini"
      assert result.family == "gpt-4o"
      assert result.doc_url == "https://platform.openai.com/docs/models/gpt-4o-mini"
      assert result.release_date == "2024-07-18"
      assert result.last_updated == "2024-10-01"
      assert result.knowledge == "2023-10"
      assert result.limits.context == 128_000
      assert result.limits.output == 16_384
      assert result.cost.input == 0.15
      assert result.cost.output == 0.60
      assert result.modalities.input == [:text, :image]
      assert result.modalities.output == [:text]
      assert result.capabilities.chat == true
      assert result.capabilities.tools.enabled == true
      assert result.capabilities.tools.streaming == true
      assert result.execution.text.supported == true
      assert result.execution.text.family == "openai_chat_compatible"
      assert result.execution.text.wire_protocol == "openai_chat"
      assert result.execution.text.transport == "http_request"
      assert result.tags == ["fast", "cheap"]
      assert result.deprecated == false
      assert result.aliases == ["gpt-4o-mini-latest"]
      assert result.extra == %{"custom" => "value"}
    end

    test "normalizes execution atoms through Model.new/1" do
      input = %{
        id: "gpt-4o-mini",
        provider: :openai,
        execution: %{
          text: %{
            supported: true,
            family: :openai_chat_compatible,
            wire_protocol: :openai_chat,
            transport: :http_request
          }
        }
      }

      assert {:ok, result} = Model.new(input)
      assert result.execution.text.family == "openai_chat_compatible"
      assert result.execution.text.wire_protocol == "openai_chat"
      assert result.execution.text.transport == "http_request"
    end

    test "keeps an omitted execution transport null" do
      input = %{
        id: "jev-1.13",
        provider: :openrouter,
        execution: %{
          evaluate: %{
            supported: true,
            family: "openrouter_decisions",
            wire_protocol: "openrouter_decisions",
            path: "/api/alpha/decisions"
          }
        }
      }

      assert {:ok, result} = Model.new(input)
      assert result.execution.evaluate.transport == nil
    end

    test "parses extended limits, capabilities, and pricing component metadata" do
      input = %{
        id: "gpt-5.5",
        provider: :openai,
        limits: %{context: 1_050_000, input: 1_050_000, output: 128_000},
        capabilities: %{
          reasoning: %{
            enabled: true,
            effort: %{supported: true, values: ["none", "low", "medium"], default: "medium"},
            thinking: %{
              supported: true,
              types: ["adaptive"],
              default_type: "adaptive",
              disable_supported: false,
              raw_output_supported: false
            },
            token_budget: %{min: 0, max: 128_000, default: 16_000}
          },
          batch: %{supported: true},
          citations: %{supported: true},
          code_execution: %{supported: true},
          context_management: %{supported: true, features: ["compact"]}
        },
        pricing: %{
          currency: "USD",
          components: [
            %{
              id: "token.input.long_context",
              kind: "token",
              unit: "token",
              per: 1_000_000,
              rate: 10.0,
              multiplier: 2.0,
              derives_from: "token.input",
              applies_to: ["token.*"],
              applies_when: %{input_tokens: %{gt: 272_000}},
              excludes_when: %{api: "batch"},
              mode: "standard",
              charge_scope: "full_request",
              source: "provider_docs",
              notes: "Long-context tier"
            }
          ]
        }
      }

      assert {:ok, result} = Model.new(input)

      assert result.limits.input == 1_050_000
      assert result.capabilities.reasoning.effort.values == ["none", "low", "medium"]
      assert result.capabilities.reasoning.effort.default == "medium"
      assert result.capabilities.reasoning.thinking.types == ["adaptive"]
      assert result.capabilities.reasoning.token_budget.max == 128_000
      assert result.capabilities.batch.supported == true
      assert result.capabilities.context_management.features == ["compact"]

      [component] = result.pricing.components
      assert component.applies_when.input_tokens.gt == 272_000
      assert component.excludes_when.api == "batch"
      assert component.multiplier == 2.0
      assert component.derives_from == "token.input"
      assert component.applies_to == ["token.*"]
      assert component.charge_scope == "full_request"
      assert component.source == "provider_docs"
    end
  end

  describe "defaults" do
    test "deprecated defaults to false" do
      input = %{id: "gpt-4o", provider: :openai}
      assert {:ok, result} = Zoi.parse(Model.schema(), input)
      assert result.deprecated == false
    end

    test "aliases defaults to empty list" do
      input = %{id: "gpt-4o", provider: :openai}
      assert {:ok, result} = Zoi.parse(Model.schema(), input)
      assert result.aliases == []
    end

    test "can override deprecated to true" do
      input = %{id: "gpt-3.5-turbo", provider: :openai, deprecated: true}
      assert {:ok, result} = Zoi.parse(Model.schema(), input)
      assert result.deprecated == true
    end
  end

  describe "optional fields" do
    test "provider_model_id is optional" do
      input = %{id: "gpt-4o", provider: :openai}
      assert {:ok, result} = Zoi.parse(Model.schema(), input)
      assert result.provider_model_id == nil
    end

    test "name is optional" do
      input = %{id: "gpt-4o", provider: :openai}
      assert {:ok, result} = Zoi.parse(Model.schema(), input)
      assert result.name == nil
    end

    test "family is optional" do
      input = %{id: "gpt-4o", provider: :openai}
      assert {:ok, result} = Zoi.parse(Model.schema(), input)
      assert result.family == nil
    end

    test "release_date is optional" do
      input = %{id: "gpt-4o", provider: :openai}
      assert {:ok, result} = Zoi.parse(Model.schema(), input)
      assert result.release_date == nil
    end

    test "last_updated is optional" do
      input = %{id: "gpt-4o", provider: :openai}
      assert {:ok, result} = Zoi.parse(Model.schema(), input)
      assert result.last_updated == nil
    end

    test "knowledge is optional" do
      input = %{id: "gpt-4o", provider: :openai}
      assert {:ok, result} = Zoi.parse(Model.schema(), input)
      assert result.knowledge == nil
    end

    test "base_url is optional" do
      input = %{id: "gpt-4o", provider: :openai}
      assert {:ok, result} = Zoi.parse(Model.schema(), input)
      assert result.base_url == nil
    end

    test "limits is optional" do
      input = %{id: "gpt-4o", provider: :openai}
      assert {:ok, result} = Zoi.parse(Model.schema(), input)
      assert result.limits == nil
    end

    test "cost is optional" do
      input = %{id: "gpt-4o", provider: :openai}
      assert {:ok, result} = Zoi.parse(Model.schema(), input)
      assert result.cost == nil
    end

    test "modalities is optional" do
      input = %{id: "gpt-4o", provider: :openai}
      assert {:ok, result} = Zoi.parse(Model.schema(), input)
      assert result.modalities == nil
    end

    test "capabilities is optional" do
      input = %{id: "gpt-4o", provider: :openai}
      assert {:ok, result} = Zoi.parse(Model.schema(), input)
      assert result.capabilities == nil
    end

    test "tags is optional" do
      input = %{id: "gpt-4o", provider: :openai}
      assert {:ok, result} = Zoi.parse(Model.schema(), input)
      assert result.tags == nil
    end

    test "extra is optional" do
      input = %{id: "gpt-4o", provider: :openai}
      assert {:ok, result} = Zoi.parse(Model.schema(), input)
      assert result.extra == nil
    end

    test "catalog_only defaults to false" do
      input = %{id: "gpt-4o", provider: :openai}
      assert {:ok, result} = Zoi.parse(Model.schema(), input)
      assert result.catalog_only == false
    end
  end

  describe "invalid inputs" do
    test "rejects missing id" do
      input = %{provider: :openai}
      assert {:error, _} = Zoi.parse(Model.schema(), input)
    end

    test "rejects missing provider" do
      input = %{id: "gpt-4o"}
      assert {:error, _} = Zoi.parse(Model.schema(), input)
    end

    test "rejects non-string id" do
      input = %{id: :gpt_4o, provider: :openai}
      assert {:error, _} = Zoi.parse(Model.schema(), input)
    end

    test "rejects non-atom provider" do
      input = %{id: "gpt-4o", provider: "openai"}
      assert {:error, _} = Zoi.parse(Model.schema(), input)
    end

    test "rejects non-string name" do
      input = %{id: "gpt-4o", provider: :openai, name: 123}
      assert {:error, _} = Zoi.parse(Model.schema(), input)
    end

    test "rejects non-boolean deprecated" do
      input = %{id: "gpt-4o", provider: :openai, deprecated: "true"}
      assert {:error, _} = Zoi.parse(Model.schema(), input)
    end

    test "rejects non-array aliases" do
      input = %{id: "gpt-4o", provider: :openai, aliases: "gpt-4o-latest"}
      assert {:error, _} = Zoi.parse(Model.schema(), input)
    end

    test "rejects non-string elements in aliases" do
      input = %{id: "gpt-4o", provider: :openai, aliases: ["gpt-4o-latest", 123]}
      assert {:error, _} = Zoi.parse(Model.schema(), input)
    end

    test "rejects non-array tags" do
      input = %{id: "gpt-4o", provider: :openai, tags: "fast"}
      assert {:error, _} = Zoi.parse(Model.schema(), input)
    end
  end

  describe "nested schema validation" do
    test "validates limits schema" do
      input = %{
        id: "gpt-4o",
        provider: :openai,
        limits: %{context: -1}
      }

      assert {:error, _} = Zoi.parse(Model.schema(), input)
    end

    test "validates cost schema" do
      input = %{
        id: "gpt-4o",
        provider: :openai,
        cost: %{input: "invalid"}
      }

      assert {:error, _} = Zoi.parse(Model.schema(), input)
    end

    test "validates capabilities schema" do
      input = %{
        id: "gpt-4o",
        provider: :openai,
        capabilities: %{chat: "true"}
      }

      assert {:error, _} = Zoi.parse(Model.schema(), input)
    end
  end

  describe "modalities" do
    test "parses modalities with input and output" do
      input = %{
        id: "gpt-4o",
        provider: :openai,
        modalities: %{
          input: [:text, :image, :audio],
          output: [:text, :audio]
        }
      }

      assert {:ok, result} = Zoi.parse(Model.schema(), input)
      assert result.modalities.input == [:text, :image, :audio]
      assert result.modalities.output == [:text, :audio]
    end

    test "modalities input is optional" do
      input = %{
        id: "gpt-4o",
        provider: :openai,
        modalities: %{output: [:text]}
      }

      assert {:ok, result} = Zoi.parse(Model.schema(), input)
      refute Map.has_key?(result.modalities, :input)
      assert result.modalities.output == [:text]
    end

    test "modalities output is optional" do
      input = %{
        id: "gpt-4o",
        provider: :openai,
        modalities: %{input: [:text]}
      }

      assert {:ok, result} = Zoi.parse(Model.schema(), input)
      assert result.modalities.input == [:text]
      refute Map.has_key?(result.modalities, :output)
    end

    test "rejects non-atom modalities" do
      input = %{
        id: "gpt-4o",
        provider: :openai,
        modalities: %{input: ["text"]}
      }

      assert {:error, _} = Zoi.parse(Model.schema(), input)
    end
  end

  describe "extra fields pass through" do
    test "extra field contains unknown upstream keys" do
      input = %{
        id: "gpt-4o",
        provider: :openai,
        extra: %{
          "upstream_id" => "abc123",
          "custom_metadata" => %{"foo" => "bar"}
        }
      }

      assert {:ok, result} = Zoi.parse(Model.schema(), input)
      assert result.extra["upstream_id"] == "abc123"
      assert result.extra["custom_metadata"] == %{"foo" => "bar"}
    end
  end

  describe "cost schema" do
    test "parses cost with all fields" do
      input = %{
        id: "o1",
        provider: :openai,
        cost: %{
          input: 0.15,
          output: 0.60,
          request: 0.01,
          cache_read: 0.015,
          cache_write: 0.30,
          training: 3.00,
          reasoning: 1.00,
          image: 1.25,
          audio: 0.50,
          input_audio: 0.75,
          output_audio: 2.00,
          input_video: 1.50,
          output_video: 3.00
        }
      }

      assert {:ok, result} = Zoi.parse(Model.schema(), input)
      assert result.cost.input == 0.15
      assert result.cost.output == 0.60
      assert result.cost.request == 0.01
      assert result.cost.cache_read == 0.015
      assert result.cost.cache_write == 0.30
      assert result.cost.training == 3.00
      assert result.cost.reasoning == 1.00
      assert result.cost.image == 1.25
      assert result.cost.audio == 0.50
      assert result.cost.input_audio == 0.75
      assert result.cost.output_audio == 2.00
      assert result.cost.input_video == 1.50
      assert result.cost.output_video == 3.00
    end

    test "parses cost with only reasoning" do
      input = %{
        id: "o1",
        provider: :openai,
        cost: %{reasoning: 1.00}
      }

      assert {:ok, result} = Zoi.parse(Model.schema(), input)
      assert result.cost.reasoning == 1.00
    end

    test "parses cost with audio fields" do
      input = %{
        id: "gemini-2.5-flash",
        provider: :google,
        cost: %{
          input: 0.15,
          output: 0.60,
          input_audio: 0.75,
          output_audio: 2.00
        }
      }

      assert {:ok, result} = Zoi.parse(Model.schema(), input)
      assert result.cost.input == 0.15
      assert result.cost.output == 0.60
      assert result.cost.input_audio == 0.75
      assert result.cost.output_audio == 2.00
    end

    test "parses cost with video fields" do
      input = %{
        id: "test-model",
        provider: :test,
        cost: %{
          input_video: 1.50,
          output_video: 3.00
        }
      }

      assert {:ok, result} = Zoi.parse(Model.schema(), input)
      assert result.cost.input_video == 1.50
      assert result.cost.output_video == 3.00
    end

    test "all cost fields are optional" do
      input = %{
        id: "test-model",
        provider: :test,
        cost: %{}
      }

      assert {:ok, result} = Zoi.parse(Model.schema(), input)
      assert result.cost == %{}
    end

    test "accepts integer cost values" do
      input = %{
        id: "test-model",
        provider: :test,
        cost: %{input: 1, output: 2}
      }

      assert {:ok, result} = Zoi.parse(Model.schema(), input)
      assert result.cost.input == 1
      assert result.cost.output == 2
    end

    test "accepts zero cost values" do
      input = %{
        id: "test-model",
        provider: :test,
        cost: %{input: 0.0, reasoning: 0.0}
      }

      assert {:ok, result} = Zoi.parse(Model.schema(), input)
      assert result.cost.input == 0.0
      assert result.cost.reasoning == 0.0
    end
  end
end
