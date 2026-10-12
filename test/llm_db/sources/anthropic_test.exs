defmodule LLMDB.Sources.AnthropicTest do
  use ExUnit.Case, async: true

  alias LLMDB.{Sources.Anthropic, Validate}

  describe "transform/1" do
    test "maps Models API fields into canonical model metadata" do
      input = %{
        "data" => [
          %{
            "id" => "claude-opus-4-8",
            "type" => "model",
            "display_name" => "Claude Opus 4.8",
            "created_at" => "2026-05-28T00:00:00Z",
            "max_input_tokens" => 1_000_000,
            "max_tokens" => 128_000,
            "capabilities" => %{
              "batch" => %{"supported" => true},
              "citations" => %{"supported" => true},
              "code_execution" => %{"supported" => true},
              "context_management" => %{
                "clear_thinking_20251015" => %{"supported" => true},
                "clear_tool_uses_20250919" => %{"supported" => true},
                "compact_20260112" => %{"supported" => true},
                "supported" => true
              },
              "effort" => %{
                "high" => %{"supported" => true},
                "low" => %{"supported" => true},
                "max" => %{"supported" => true},
                "medium" => %{"supported" => true},
                "supported" => true,
                "xhigh" => %{"supported" => true}
              },
              "image_input" => %{"supported" => true},
              "pdf_input" => %{"supported" => true},
              "structured_outputs" => %{"supported" => true},
              "thinking" => %{
                "supported" => true,
                "types" => %{
                  "adaptive" => %{"supported" => true},
                  "enabled" => %{"supported" => false}
                }
              }
            }
          }
        ]
      }

      assert %{"anthropic" => %{models: [model]}} = Anthropic.transform(input)

      assert model.id == "claude-opus-4-8"
      assert model.provider == :anthropic
      assert model.name == "Claude Opus 4.8"
      assert model.release_date == "2026-05-28"
      assert model.limits == %{context: 1_000_000, input: 1_000_000, output: 128_000}
      assert model.modalities == %{input: [:text, :image, :pdf], output: [:text]}
      assert model.capabilities.reasoning.enabled == true

      assert model.capabilities.reasoning.effort.values == [
               "low",
               "medium",
               "high",
               "xhigh",
               "max"
             ]

      assert model.capabilities.reasoning.thinking.types == ["adaptive"]
      assert model.capabilities.reasoning.thinking.default_type == "adaptive"
      assert model.capabilities.reasoning.thinking.disable_supported == false
      assert model.capabilities.json.schema == true
      assert model.capabilities.batch.supported == true
      assert model.capabilities.citations.supported == true
      assert model.capabilities.code_execution.supported == true

      assert model.capabilities.context_management.features == [
               "clear_thinking",
               "clear_tool_uses",
               "compact"
             ]

      assert model.extra.type == "model"
      assert model.extra.provider_capabilities["effort"]["max"]["supported"] == true

      assert {:ok, validated} = Validate.validate_model_overlay(model)
      assert validated.limits == model.limits
      assert validated.capabilities == model.capabilities
    end

    test "between_tools supports turning off up-front thinking without enabling disabled" do
      input = %{
        "data" => [
          %{
            "id" => "claude-sonnet-5-5",
            "capabilities" => %{
              "thinking" => %{
                "supported" => true,
                "types" => %{
                  "adaptive" => %{"supported" => true},
                  "between_tools" => %{"supported" => true},
                  "disabled" => %{"supported" => false}
                }
              }
            }
          }
        ]
      }

      assert %{"anthropic" => %{models: [model]}} = Anthropic.transform(input)
      assert model.capabilities.reasoning.thinking.types == ["adaptive", "between_tools"]
      assert model.capabilities.reasoning.thinking.default_type == "adaptive"
      assert model.capabilities.reasoning.thinking.disable_supported
      refute model.extra.provider_capabilities["thinking"]["types"]["disabled"]["supported"]
      assert {:ok, _} = Validate.validate_model_overlay(model)
    end

    test "supplements the documented Sonnet mode when the Models API omits it" do
      input = %{
        "data" => [
          %{
            "id" => "claude-sonnet-5-5",
            "capabilities" => %{
              "thinking" => %{
                "supported" => true,
                "types" => %{
                  "adaptive" => %{"supported" => true},
                  "disabled" => %{"supported" => false}
                }
              }
            }
          }
        ]
      }

      assert %{"anthropic" => %{models: [model]}} = Anthropic.transform(input)
      assert model.capabilities.reasoning.thinking.types == ["adaptive", "between_tools"]
      assert model.capabilities.reasoning.thinking.disable_supported
      assert model.extra.provider_capabilities["thinking"]["types"]["between_tools"]["supported"]
    end
  end
end
