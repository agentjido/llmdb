defmodule LLMDB.Schema.ProviderTest do
  use ExUnit.Case, async: true

  alias LLMDB.Provider

  describe "valid parsing" do
    test "parses minimal valid provider" do
      input = %{id: :openai}
      assert {:ok, result} = Zoi.parse(Provider.schema(), input)
      assert result.id == :openai
    end

    test "parses complete provider with all fields" do
      input = %{
        id: :openai,
        name: "OpenAI",
        base_url: "https://api.openai.com",
        env: ["OPENAI_API_KEY"],
        doc: "OpenAI provider",
        extra: %{"custom" => "value"}
      }

      assert {:ok, result} = Zoi.parse(Provider.schema(), input)
      assert result.id == :openai
      assert result.name == "OpenAI"
      assert result.base_url == "https://api.openai.com"
      assert result.env == ["OPENAI_API_KEY"]
      assert result.doc == "OpenAI provider"
      assert result.extra == %{"custom" => "value"}
    end

    test "parses provider with multiple env vars" do
      input = %{
        id: :anthropic,
        env: ["ANTHROPIC_API_KEY", "ANTHROPIC_ORG_ID"]
      }

      assert {:ok, result} = Zoi.parse(Provider.schema(), input)
      assert result.env == ["ANTHROPIC_API_KEY", "ANTHROPIC_ORG_ID"]
    end

    test "parses typed runtime metadata" do
      input = %{
        id: :openai,
        runtime: %{
          base_url: "https://api.openai.com/v1",
          auth: %{
            type: "bearer",
            env: ["OPENAI_API_KEY"]
          },
          default_headers: %{"openai-beta" => "responses=v1"},
          default_query: %{"project" => "demo"},
          config_schema: [
            %{name: "project", type: "string", required: false, doc: "OpenAI project override"}
          ],
          doc_url: "https://platform.openai.com/docs/api-reference"
        }
      }

      assert {:ok, result} = Zoi.parse(Provider.schema(), input)
      assert result.runtime.base_url == "https://api.openai.com/v1"
      assert result.runtime.auth.type == "bearer"
      assert result.runtime.auth.env == ["OPENAI_API_KEY"]
      assert result.runtime.default_headers["openai-beta"] == "responses=v1"
      assert result.runtime.default_query["project"] == "demo"
      assert hd(result.runtime.config_schema).name == "project"
      assert result.runtime.doc_url == "https://platform.openai.com/docs/api-reference"
      assert Map.get(result.runtime, :execution) == nil
    end

    test "parses additive runtime execution policy" do
      input = %{
        id: :openai,
        runtime: %{
          execution: %{
            text: "openai_chat_compatible",
            object: "openai_responses_compatible",
            rerank: "cohere_rerank_compatible"
          }
        }
      }

      assert {:ok, result} = Provider.new(input)
      assert result.runtime.execution.text == "openai_chat_compatible"
      assert result.runtime.execution.object == "openai_responses_compatible"
      assert result.runtime.execution.rerank == "cohere_rerank_compatible"
      assert Map.get(result.runtime.execution, :embed) == nil
    end

    test "normalizes auth type atoms through Provider.new/1" do
      input = %{
        id: :openai,
        runtime: %{
          base_url: "https://api.openai.com/v1",
          auth: %{type: :bearer, env: ["OPENAI_API_KEY"]}
        }
      }

      assert {:ok, result} = Provider.new(input)
      assert result.runtime.auth.type == "bearer"
    end

    test "parses pricing defaults with conditional component metadata" do
      input = %{
        id: :anthropic,
        pricing_defaults: %{
          currency: "USD",
          components: [
            %{
              id: "pricing.data_residency",
              kind: "other",
              unit: "other",
              multiplier: 1.1,
              applies_to: ["token.*"],
              applies_when: %{inference_geo: true},
              charge_scope: "full_request",
              source: "provider_docs"
            }
          ]
        }
      }

      assert {:ok, result} = Provider.new(input)

      [component] = result.pricing_defaults.components
      assert component.multiplier == 1.1
      assert component.applies_to == ["token.*"]
      assert component.applies_when.inference_geo == true
      assert component.charge_scope == "full_request"
      assert component.source == "provider_docs"
    end
  end

  describe "optional fields" do
    test "name is optional" do
      input = %{id: :openai}
      assert {:ok, result} = Zoi.parse(Provider.schema(), input)
      assert result.name == nil
    end

    test "base_url is optional" do
      input = %{id: :openai}
      assert {:ok, result} = Zoi.parse(Provider.schema(), input)
      assert result.base_url == nil
    end

    test "env is optional" do
      input = %{id: :openai}
      assert {:ok, result} = Zoi.parse(Provider.schema(), input)
      assert result.env == nil
    end

    test "doc is optional" do
      input = %{id: :openai}
      assert {:ok, result} = Zoi.parse(Provider.schema(), input)
      assert result.doc == nil
    end

    test "extra is optional" do
      input = %{id: :openai}
      assert {:ok, result} = Zoi.parse(Provider.schema(), input)
      assert result.extra == nil
    end

    test "catalog_only defaults to false" do
      input = %{id: :openai}
      assert {:ok, result} = Zoi.parse(Provider.schema(), input)
      assert result.catalog_only == false
    end
  end

  describe "invalid inputs" do
    test "rejects missing id" do
      input = %{name: "OpenAI"}
      assert {:error, _} = Zoi.parse(Provider.schema(), input)
    end

    test "rejects non-atom id" do
      input = %{id: "openai"}
      assert {:error, _} = Zoi.parse(Provider.schema(), input)
    end

    test "rejects non-string name" do
      input = %{id: :openai, name: 123}
      assert {:error, _} = Zoi.parse(Provider.schema(), input)
    end

    test "rejects non-string base_url" do
      input = %{id: :openai, base_url: 123}
      assert {:error, _} = Zoi.parse(Provider.schema(), input)
    end

    test "rejects non-array env" do
      input = %{id: :openai, env: "OPENAI_API_KEY"}
      assert {:error, _} = Zoi.parse(Provider.schema(), input)
    end

    test "rejects non-string elements in env array" do
      input = %{id: :openai, env: ["OPENAI_API_KEY", 123]}
      assert {:error, _} = Zoi.parse(Provider.schema(), input)
    end

    test "rejects non-map extra" do
      input = %{id: :openai, extra: "not a map"}
      assert {:error, _} = Zoi.parse(Provider.schema(), input)
    end
  end

  describe "extra fields pass through" do
    test "extra field contains unknown upstream keys" do
      input = %{
        id: :openai,
        extra: %{"upstream_version" => "1.0", "custom_field" => true}
      }

      assert {:ok, result} = Zoi.parse(Provider.schema(), input)
      assert result.extra["upstream_version"] == "1.0"
      assert result.extra["custom_field"] == true
    end
  end
end
