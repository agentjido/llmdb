defmodule LLMDB.Sources.OpenRouterTest do
  use ExUnit.Case, async: false

  alias LLMDB.Sources.OpenRouter

  setup do
    # Clean up test cache directory
    File.rm_rf!("tmp/test/upstream")

    on_exit(fn ->
      File.rm_rf!("tmp/test/upstream")
    end)

    :ok
  end

  defp make_plug(fun) do
    fn conn ->
      fun.(conn)
    end
  end

  describe "pull/1" do
    test "fetches and caches data on 200 response" do
      test_url = "https://test.openrouter.ai/api/v1/models"

      body = %{
        "data" => [
          %{
            "id" => "openai/gpt-4",
            "name" => "GPT-4",
            "context_length" => 128_000,
            "pricing" => %{
              "prompt" => "0.00003",
              "completion" => "0.00006"
            },
            "architecture" => %{
              "modality" => "text->text"
            },
            "top_provider" => %{
              "max_completion_tokens" => 16_384
            }
          }
        ]
      }

      plug =
        make_plug(fn conn ->
          conn
          |> Plug.Conn.put_resp_header("etag", "abc123")
          |> Plug.Conn.put_resp_header("last-modified", "Mon, 01 Jan 2024")
          |> Plug.Conn.send_resp(200, Jason.encode!(body))
        end)

      assert {:ok, cache_path} = OpenRouter.pull(%{url: test_url, req_opts: [plug: plug]})

      assert File.exists?(cache_path)
      {:ok, cached} = File.read(cache_path)
      decoded = Jason.decode!(cached)
      assert decoded["data"]

      manifest_path = String.replace_suffix(cache_path, ".json", ".manifest.json")
      assert File.exists?(manifest_path)
      {:ok, manifest_bin} = File.read(manifest_path)
      manifest = Jason.decode!(manifest_bin)
      assert manifest["etag"] == "abc123"
      assert manifest["last_modified"] == "Mon, 01 Jan 2024"
      assert manifest["sha256"]
      assert manifest["downloaded_at"]
    end

    test "returns :noop on 304 not modified" do
      plug = make_plug(fn conn -> Plug.Conn.send_resp(conn, 304, "") end)
      assert :noop = OpenRouter.pull(%{req_opts: [plug: plug]})
    end

    test "requests all output modalities by default" do
      body = %{"data" => []}

      plug =
        make_plug(fn conn ->
          assert conn.query_string == "output_modalities=all"
          Plug.Conn.send_resp(conn, 200, Jason.encode!(body))
        end)

      assert {:ok, _cache_path} = OpenRouter.pull(%{req_opts: [plug: plug]})
    end

    test "returns error on non-200/304 status" do
      plug = make_plug(fn conn -> Plug.Conn.send_resp(conn, 404, "Not Found") end)
      assert {:error, {:http_status, 404}} = OpenRouter.pull(%{req_opts: [plug: plug]})
    end

    test "sends conditional headers from manifest on subsequent pulls" do
      test_url = "https://test.openrouter.ai/api/v1/models"
      body = %{"data" => []}

      plug_first =
        make_plug(fn conn ->
          conn
          |> Plug.Conn.put_resp_header("etag", "tag1")
          |> Plug.Conn.put_resp_header("last-modified", "Mon, 01 Jan 2024")
          |> Plug.Conn.send_resp(200, Jason.encode!(body))
        end)

      OpenRouter.pull(%{url: test_url, req_opts: [plug: plug_first]})

      plug_second =
        make_plug(fn conn ->
          headers = Enum.into(conn.req_headers, %{})
          assert headers["if-none-match"] == "tag1"
          assert headers["if-modified-since"] == "Mon, 01 Jan 2024"

          Plug.Conn.send_resp(conn, 304, "")
        end)

      assert :noop = OpenRouter.pull(%{url: test_url, req_opts: [plug: plug_second]})
    end

    test "includes authorization header when api_key provided" do
      body = %{"data" => []}

      plug =
        make_plug(fn conn ->
          headers = Enum.into(conn.req_headers, %{})
          assert headers["authorization"] == "Bearer test-api-key"
          Plug.Conn.send_resp(conn, 200, Jason.encode!(body))
        end)

      OpenRouter.pull(%{api_key: "test-api-key", req_opts: [plug: plug]})
    end
  end

  describe "load/1" do
    test "loads and transforms cached OpenRouter data" do
      test_url = "https://test.openrouter.ai/api/v1/models"

      cache_data = %{
        "data" => [
          %{
            "id" => "openai/gpt-4",
            "name" => "GPT-4",
            "description" => "GPT-4 by OpenAI",
            "context_length" => 128_000,
            "pricing" => %{
              "prompt" => "0.00003",
              "completion" => "0.00006"
            },
            "architecture" => %{
              "modality" => "text->text"
            },
            "top_provider" => %{
              "max_completion_tokens" => 16_384
            },
            "created" => 1_672_531_200,
            "supported_parameters" => ["temperature", "top_p", "tools"]
          }
        ]
      }

      hash = :crypto.hash(:sha256, test_url) |> Base.encode16(case: :lower) |> binary_part(0, 8)
      cache_path = "tmp/test/upstream/openrouter-#{hash}.json"

      File.mkdir_p!(Path.dirname(cache_path))
      File.write!(cache_path, Jason.encode!(cache_data))

      {:ok, data} = OpenRouter.load(%{url: test_url})

      assert is_map(data)
      assert Map.has_key?(data, "openrouter")

      provider = data["openrouter"]
      assert provider[:id] == :openrouter
      assert provider[:name] == "OpenRouter"
      assert is_list(provider[:models])
      assert length(provider[:models]) == 1

      model = hd(provider[:models])
      # Full OpenRouter model ID is preserved (including the "/")
      assert model[:id] == "openai/gpt-4"
      assert model[:provider] == :openrouter
      assert model[:name] == "GPT-4"
      assert model[:description] == "GPT-4 by OpenAI"
      assert model[:limits][:context] == 128_000
      assert model[:limits][:output] == 16_384
      assert_in_delta model[:cost][:input], 30.0, 0.001
      assert_in_delta model[:cost][:output], 60.0, 0.001
      assert model[:modalities][:input] == [:text]
      assert model[:modalities][:output] == [:text]
      assert model[:capabilities][:tools][:enabled] == true
      assert model[:release_date] == "2023-01-01"
    end

    test "keeps all models under :openrouter with full IDs" do
      test_url = "https://test.openrouter.ai/api/v1/models"

      cache_data = %{
        "data" => [
          %{
            "id" => "openai/gpt-4",
            "name" => "GPT-4"
          },
          %{
            "id" => "openai/gpt-3.5-turbo",
            "name" => "GPT-3.5 Turbo"
          },
          %{
            "id" => "anthropic/claude-3-5-sonnet",
            "name" => "Claude 3.5 Sonnet"
          },
          %{
            "id" => "perplexity/sonar-pro",
            "name" => "Perplexity: Sonar Pro"
          }
        ]
      }

      hash = :crypto.hash(:sha256, test_url) |> Base.encode16(case: :lower) |> binary_part(0, 8)
      cache_path = "tmp/test/upstream/openrouter-#{hash}.json"

      File.mkdir_p!(Path.dirname(cache_path))
      File.write!(cache_path, Jason.encode!(cache_data))

      {:ok, data} = OpenRouter.load(%{url: test_url})

      # Only :openrouter provider - no splitting by upstream provider
      assert map_size(data) == 1
      assert Map.has_key?(data, "openrouter")
      refute Map.has_key?(data, "openai")
      refute Map.has_key?(data, "anthropic")
      refute Map.has_key?(data, "perplexity")

      openrouter_models = data["openrouter"][:models]
      assert length(openrouter_models) == 4

      # All models have :openrouter as provider and keep full IDs
      assert Enum.all?(openrouter_models, fn m -> m[:provider] == :openrouter end)

      # Model IDs include the "/" - they are not split
      model_ids = Enum.map(openrouter_models, & &1[:id])
      assert "openai/gpt-4" in model_ids
      assert "openai/gpt-3.5-turbo" in model_ids
      assert "anthropic/claude-3-5-sonnet" in model_ids
      assert "perplexity/sonar-pro" in model_ids
    end

    test "handles models without provider prefix" do
      test_url = "https://test.openrouter.ai/api/v1/models"

      cache_data = %{
        "data" => [
          %{
            "id" => "custom-model",
            "name" => "Custom Model"
          }
        ]
      }

      hash = :crypto.hash(:sha256, test_url) |> Base.encode16(case: :lower) |> binary_part(0, 8)
      cache_path = "tmp/test/upstream/openrouter-#{hash}.json"

      File.mkdir_p!(Path.dirname(cache_path))
      File.write!(cache_path, Jason.encode!(cache_data))

      {:ok, data} = OpenRouter.load(%{url: test_url})

      assert Map.has_key?(data, "openrouter")
      model = hd(data["openrouter"][:models])
      assert model[:id] == "custom-model"
      assert model[:provider] == :openrouter
    end

    test "handles multi-modal models" do
      test_url = "https://test.openrouter.ai/api/v1/models"

      cache_data = %{
        "data" => [
          %{
            "id" => "openai/gpt-4-vision",
            "name" => "GPT-4 Vision",
            "architecture" => %{
              "modality" => "text+image->text"
            }
          }
        ]
      }

      hash = :crypto.hash(:sha256, test_url) |> Base.encode16(case: :lower) |> binary_part(0, 8)
      cache_path = "tmp/test/upstream/openrouter-#{hash}.json"

      File.mkdir_p!(Path.dirname(cache_path))
      File.write!(cache_path, Jason.encode!(cache_data))

      {:ok, data} = OpenRouter.load(%{url: test_url})

      model = hd(data["openrouter"][:models])
      assert model[:id] == "openai/gpt-4-vision"
      assert model[:modalities][:input] == [:text, :image]
      assert model[:modalities][:output] == [:text]
    end

    test "returns error when cache file missing" do
      test_url = "https://missing.openrouter.ai/api/v1/models"
      assert {:error, :no_cache} = OpenRouter.load(%{url: test_url})
    end

    test "returns error on invalid JSON" do
      test_url = "https://invalid.openrouter.ai/api/v1/models"
      hash = :crypto.hash(:sha256, test_url) |> Base.encode16(case: :lower) |> binary_part(0, 8)
      cache_path = "tmp/test/upstream/openrouter-#{hash}.json"

      File.mkdir_p!(Path.dirname(cache_path))
      File.write!(cache_path, "not json")

      assert {:error, {:json_error, _}} = OpenRouter.load(%{url: test_url})
    end
  end

  describe "output_modalities embedding detection" do
    test "sets embeddings capability when output_modalities contains 'embedding'" do
      input = %{
        "data" => [
          %{
            "id" => "baai/bge-m3",
            "name" => "BGE-M3",
            "architecture" => %{
              "modality" => "text->text",
              "output_modalities" => ["embedding"]
            }
          }
        ]
      }

      result = OpenRouter.transform(input)
      model = hd(result["openrouter"][:models])

      assert model[:capabilities][:embeddings] == true
    end

    test "sets embeddings capability when output_modalities contains 'embeddings'" do
      input = %{
        "data" => [
          %{
            "id" => "google/gemini-embedding-2",
            "name" => "Google: Gemini Embedding 2",
            "architecture" => %{
              "modality" => "text->embeddings",
              "output_modalities" => ["embeddings"]
            }
          }
        ]
      }

      result = OpenRouter.transform(input)
      model = hd(result["openrouter"][:models])

      assert model[:modalities][:output] == [:embeddings]
      assert model[:capabilities][:embeddings] == true
    end

    test "does not set embeddings capability when output_modalities lacks 'embedding'" do
      input = %{
        "data" => [
          %{
            "id" => "openai/gpt-4",
            "name" => "GPT-4",
            "architecture" => %{
              "modality" => "text->text",
              "output_modalities" => ["text"]
            }
          }
        ]
      }

      result = OpenRouter.transform(input)
      model = hd(result["openrouter"][:models])

      refute get_in(model, [:capabilities, :embeddings])
    end

    test "does not set embeddings capability when architecture has no output_modalities" do
      input = %{
        "data" => [
          %{
            "id" => "openai/gpt-4",
            "name" => "GPT-4",
            "architecture" => %{"modality" => "text->text"}
          }
        ]
      }

      result = OpenRouter.transform(input)
      model = hd(result["openrouter"][:models])

      refute get_in(model, [:capabilities, :embeddings])
    end

    test "does not set embeddings capability when architecture is nil" do
      input = %{
        "data" => [%{"id" => "openai/gpt-4", "name" => "GPT-4"}]
      }

      result = OpenRouter.transform(input)
      model = hd(result["openrouter"][:models])

      refute get_in(model, [:capabilities, :embeddings])
    end

    test "sets both tools and embeddings capabilities together" do
      input = %{
        "data" => [
          %{
            "id" => "some/embed-tools-model",
            "name" => "Embed Tools Model",
            "architecture" => %{
              "modality" => "text->text",
              "output_modalities" => ["embedding"]
            },
            "supported_parameters" => ["tools"]
          }
        ]
      }

      result = OpenRouter.transform(input)
      model = hd(result["openrouter"][:models])

      assert model[:capabilities][:embeddings] == true
      assert model[:capabilities][:tools][:enabled] == true
    end
  end

  describe "pricing mapping" do
    test "maps OpenRouter token and tool pricing fields" do
      input = %{
        "data" => [
          %{
            "id" => "google/gemini-3.5-flash",
            "name" => "Google: Gemini 3.5 Flash",
            "pricing" => %{
              "prompt" => "0.0000015",
              "completion" => "0.000009",
              "input_cache_read" => "0.00000015",
              "input_cache_write" => "0.00000008333333333333334",
              "internal_reasoning" => "0.000009",
              "image" => "0.0000015",
              "audio" => "0.000003",
              "web_search" => "0.014"
            }
          }
        ]
      }

      result = OpenRouter.transform(input)
      model = hd(result["openrouter"][:models])

      assert_in_delta model[:cost][:input], 1.5, 0.000001
      assert_in_delta model[:cost][:output], 9.0, 0.000001
      assert_in_delta model[:cost][:cache_read], 0.15, 0.000001
      assert_in_delta model[:cost][:cache_write], 0.083333, 0.000001
      assert_in_delta model[:cost][:reasoning], 9.0, 0.000001
      assert_in_delta model[:cost][:image], 1.5, 0.000001
      assert_in_delta model[:cost][:audio], 3.0, 0.000001

      assert model[:pricing][:currency] == "USD"

      assert [
               %{
                 id: "tool.web_search",
                 kind: "tool",
                 tool: "web_search",
                 unit: "call",
                 per: 1,
                 rate: 0.014
               }
             ] = model[:pricing][:components]
    end
  end

  describe "transform/1" do
    test "transforms minimal model correctly" do
      input = %{
        "data" => [
          %{
            "id" => "test/model-1",
            "name" => "Test Model 1"
          }
        ]
      }

      result = OpenRouter.transform(input)

      # All models go under :openrouter with full IDs preserved
      assert Map.has_key?(result, "openrouter")
      provider = result["openrouter"]
      assert provider[:id] == :openrouter
      assert length(provider[:models]) == 1

      model = hd(provider[:models])
      # ID keeps the "/" - it's part of the model ID, not a provider delimiter
      assert model[:id] == "test/model-1"
      assert model[:provider] == :openrouter
      assert model[:name] == "Test Model 1"
    end

    test "handles empty data array" do
      input = %{"data" => []}
      result = OpenRouter.transform(input)
      # Even with no models, we get the openrouter provider
      assert Map.has_key?(result, "openrouter")
      assert result["openrouter"][:models] == []
    end

    test "consolidates an exact alias target into the canonical model" do
      input = %{
        "data" => [
          %{
            "id" => "anthropic/claude-fable-latest",
            "name" => "Anthropic: Claude Fable Latest",
            "alias_target" => %{"slug" => "anthropic/claude-fable-5"}
          },
          %{
            "id" => "anthropic/claude-fable-5",
            "name" => "Anthropic: Claude Fable 5"
          }
        ]
      }

      result = OpenRouter.transform(input)

      assert result["openrouter"][:exclude_models] == [
               "anthropic/claude-fable-latest"
             ]

      assert [
               %{
                 id: "anthropic/claude-fable-5",
                 aliases: ["anthropic/claude-fable-latest"]
               }
             ] = result["openrouter"][:models]
    end

    test "keeps an alias model when its target is not in the response" do
      input = %{
        "data" => [
          %{
            "id" => "anthropic/claude-fable-latest",
            "name" => "Anthropic: Claude Fable Latest",
            "alias_target" => %{"slug" => "anthropic/claude-fable-5"}
          }
        ]
      }

      result = OpenRouter.transform(input)

      assert result["openrouter"][:exclude_models] == []

      assert [
               %{
                 id: "anthropic/claude-fable-latest",
                 extra: %{alias_target: %{"slug" => "anthropic/claude-fable-5"}}
               }
             ] = result["openrouter"][:models]
    end

    test "resolves an alias chain to the final canonical model" do
      input = %{
        "data" => [
          %{
            "id" => "test/model-latest",
            "name" => "Model Latest",
            "alias_target" => %{"slug" => "test/model-current"}
          },
          %{
            "id" => "test/model-current",
            "name" => "Model Current",
            "alias_target" => %{"slug" => "test/model-1"}
          },
          %{
            "id" => "test/model-1",
            "name" => "Model 1"
          }
        ]
      }

      result = OpenRouter.transform(input)

      assert result["openrouter"][:exclude_models] == [
               "test/model-latest",
               "test/model-current"
             ]

      assert [
               %{
                 id: "test/model-1",
                 aliases: ["test/model-latest", "test/model-current"]
               }
             ] = result["openrouter"][:models]
    end

    test "keeps every model in an alias cycle" do
      input = %{
        "data" => [
          %{
            "id" => "test/model-a",
            "name" => "Model A",
            "alias_target" => %{"slug" => "test/model-b"}
          },
          %{
            "id" => "test/model-b",
            "name" => "Model B",
            "alias_target" => %{"slug" => "test/model-a"}
          }
        ]
      }

      result = OpenRouter.transform(input)

      assert result["openrouter"][:exclude_models] == []

      assert [
               %{id: "test/model-a", extra: %{alias_target: %{"slug" => "test/model-b"}}},
               %{id: "test/model-b", extra: %{alias_target: %{"slug" => "test/model-a"}}}
             ] = result["openrouter"][:models]
    end
  end

  describe "integration" do
    test "pull then load workflow" do
      test_url = "https://integration.openrouter.ai/api/v1/models"

      body = %{
        "data" => [
          %{
            "id" => "test/model-1",
            "name" => "Test Model 1",
            "context_length" => 4096
          }
        ]
      }

      plug = make_plug(fn conn -> Plug.Conn.send_resp(conn, 200, Jason.encode!(body)) end)

      assert {:ok, _} = OpenRouter.pull(%{url: test_url, req_opts: [plug: plug]})

      assert {:ok, data} = OpenRouter.load(%{url: test_url})
      assert Map.has_key?(data, "openrouter")
      assert data["openrouter"][:name] == "OpenRouter"
      assert length(data["openrouter"][:models]) == 1
      assert hd(data["openrouter"][:models])[:id] == "test/model-1"
      assert hd(data["openrouter"][:models])[:provider] == :openrouter
      assert hd(data["openrouter"][:models])[:limits][:context] == 4096
    end
  end
end
