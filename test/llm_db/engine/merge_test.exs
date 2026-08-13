defmodule LLMDB.Engine.MergeTest do
  use ExUnit.Case, async: true
  alias LLMDB.Merge

  doctest LLMDB.Merge

  describe "merge/3 scalar values" do
    test "higher precedence wins on scalar conflict" do
      base = %{value: 1}
      override = %{value: 2}
      assert Merge.merge(base, override, :higher) == %{value: 2}
    end

    test "lower precedence preserves base on scalar conflict" do
      base = %{value: 1}
      override = %{value: 2}
      assert Merge.merge(base, override, :lower) == %{value: 1}
    end

    test "combines non-conflicting scalars" do
      base = %{a: 1}
      override = %{b: 2}
      assert Merge.merge(base, override, :higher) == %{a: 1, b: 2}
    end

    test "handles nil values with higher precedence" do
      base = %{value: 1}
      override = %{value: nil}
      assert Merge.merge(base, override, :higher) == %{value: nil}
    end

    test "handles nil values with lower precedence" do
      base = %{value: nil}
      override = %{value: 2}
      assert Merge.merge(base, override, :lower) == %{value: nil}
    end
  end

  describe "merge/3 deep map merging" do
    test "deep merges nested maps" do
      base = %{config: %{api: %{timeout: 30}}}
      override = %{config: %{api: %{retries: 3}}}

      result = Merge.merge(base, override, :higher)

      assert result == %{config: %{api: %{timeout: 30, retries: 3}}}
    end

    test "higher precedence wins on nested scalar conflicts" do
      base = %{config: %{value: 1}}
      override = %{config: %{value: 2}}

      result = Merge.merge(base, override, :higher)

      assert result == %{config: %{value: 2}}
    end

    test "lower precedence preserves base on nested scalar conflicts" do
      base = %{config: %{value: 1}}
      override = %{config: %{value: 2}}

      result = Merge.merge(base, override, :lower)

      assert result == %{config: %{value: 1}}
    end

    test "merges deeply nested structures" do
      base = %{
        level1: %{
          level2: %{
            level3: %{
              value: "base"
            }
          }
        }
      }

      override = %{
        level1: %{
          level2: %{
            level3: %{
              extra: "override"
            }
          }
        }
      }

      result = Merge.merge(base, override, :higher)

      assert result == %{
               level1: %{
                 level2: %{
                   level3: %{
                     value: "base",
                     extra: "override"
                   }
                 }
               }
             }
    end
  end

  describe "merge/3 list handling" do
    test "concatenates and deduplicates lists" do
      base = %{tags: [1, 2, 3]}
      override = %{tags: [3, 4, 5]}

      result = Merge.merge(base, override, :higher)

      assert result.tags |> Enum.sort() == [1, 2, 3, 4, 5]
    end

    test "preserves list order while deduplicating" do
      base = %{items: ["a", "b"]}
      override = %{items: ["b", "c"]}

      result = Merge.merge(base, override, :higher)

      assert result.items == ["a", "b", "c"]
    end

    test "handles empty lists" do
      base = %{items: []}
      override = %{items: [1, 2]}

      result = Merge.merge(base, override, :higher)

      assert result.items == [1, 2]
    end

    test "deduplicates string lists" do
      base = %{aliases: ["test-model-v1", "gpt-4-turbo"]}
      override = %{aliases: ["gpt-4-turbo", "gpt-4-latest"]}

      result = Merge.merge(base, override, :higher)

      assert result.aliases == ["test-model-v1", "gpt-4-turbo", "gpt-4-latest"]
    end
  end

  describe "merge_providers/2" do
    test "merges providers by id with higher precedence" do
      base = [
        %{id: :test_provider_alpha, name: "Test Provider Alpha", api_version: "v1"}
      ]

      override = [
        %{id: :test_provider_alpha, name: "OpenAI Updated"}
      ]

      result = Merge.merge_providers(base, override)

      assert length(result) == 1
      provider = Enum.find(result, fn p -> p.id == :test_provider_alpha end)
      assert provider.name == "OpenAI Updated"
      assert provider.api_version == "v1"
    end

    test "combines providers from both sources" do
      base = [
        %{id: :test_provider_alpha, name: "Test Provider Alpha"}
      ]

      override = [
        %{id: :test_provider_beta, name: "Test Provider Beta"}
      ]

      result = Merge.merge_providers(base, override)

      assert length(result) == 2
      assert Enum.any?(result, fn p -> p.id == :test_provider_alpha end)
      assert Enum.any?(result, fn p -> p.id == :test_provider_beta end)
    end

    test "deep merges provider configuration" do
      base = [
        %{id: :test_provider_alpha, config: %{timeout: 30, retries: 3}}
      ]

      override = [
        %{id: :test_provider_alpha, config: %{retries: 5, max_tokens: 1000}}
      ]

      result = Merge.merge_providers(base, override)

      provider = Enum.find(result, fn p -> p.id == :test_provider_alpha end)
      assert provider.config.timeout == 30
      assert provider.config.retries == 5
      assert provider.config.max_tokens == 1000
    end

    test "keeps model exclusions from all provider sources" do
      base = [
        %{id: :test_provider_alpha, exclude_models: ["base-model"]}
      ]

      override = [
        %{id: :test_provider_alpha, exclude_models: ["override-model"]}
      ]

      [provider] = Merge.merge_providers(base, override)

      assert provider.exclude_models == ["base-model", "override-model"]
    end

    test "handles empty base list" do
      result = Merge.merge_providers([], [%{id: :test_provider_alpha}])
      assert length(result) == 1
    end

    test "handles empty override list" do
      result = Merge.merge_providers([%{id: :test_provider_alpha}], [])
      assert length(result) == 1
    end
  end

  describe "merge_models/3" do
    test "merges models by {provider, id} identity" do
      base = [
        %{id: "test-model-v1", provider: :test_provider_alpha, version: 1}
      ]

      override = [
        %{id: "test-model-v1", provider: :test_provider_alpha, version: 2}
      ]

      result = Merge.merge_models(base, override, %{})

      assert length(result) == 1
      model = Enum.find(result, fn m -> m.id == "test-model-v1" end)
      assert model.version == 2
    end

    test "combines models from both sources" do
      base = [
        %{id: "test-model-v1", provider: :test_provider_alpha}
      ]

      override = [
        %{id: "test-model-beta-v3", provider: :test_provider_beta}
      ]

      result = Merge.merge_models(base, override, %{})

      assert length(result) == 2
    end

    test "deep merges model capabilities" do
      base = [
        %{
          id: "test-model-v1",
          provider: :test_provider_alpha,
          capabilities: %{
            chat: true,
            tools: %{enabled: true, streaming: false}
          }
        }
      ]

      override = [
        %{
          id: "test-model-v1",
          provider: :test_provider_alpha,
          capabilities: %{
            tools: %{streaming: true, parallel: true}
          }
        }
      ]

      result = Merge.merge_models(base, override, %{})

      model = Enum.find(result, fn m -> m.id == "test-model-v1" end)
      assert model.capabilities.chat == true
      assert model.capabilities.tools.enabled == true
      assert model.capabilities.tools.streaming == true
      assert model.capabilities.tools.parallel == true
    end

    test "applies exact exclude patterns" do
      base = [
        %{id: "test-model-v1", provider: :test_provider_alpha},
        %{id: "test-model-old", provider: :test_provider_alpha},
        %{id: "test-model-v1-turbo", provider: :test_provider_alpha}
      ]

      excludes = %{test_provider_alpha: ["test-model-old"]}

      result = Merge.merge_models(base, [], excludes)

      assert length(result) == 2
      assert Enum.any?(result, fn m -> m.id == "test-model-v1" end)
      assert Enum.any?(result, fn m -> m.id == "test-model-v1-turbo" end)
      refute Enum.any?(result, fn m -> m.id == "test-model-old" end)
    end

    test "applies glob exclude patterns" do
      base = [
        %{id: "test-model-v1-mini", provider: :test_provider_alpha},
        %{id: "test-model-v2-pro", provider: :test_provider_alpha},
        %{id: "test-model-v2-ultra", provider: :test_provider_alpha},
        %{id: "test-model-beta-v3", provider: :test_provider_beta}
      ]

      excludes = %{test_provider_alpha: ["test-model-v2-*"]}

      result = Merge.merge_models(base, [], excludes)

      assert length(result) == 2
      assert Enum.any?(result, fn m -> m.id == "test-model-v1-mini" end)
      assert Enum.any?(result, fn m -> m.id == "test-model-beta-v3" end)
      refute Enum.any?(result, fn m -> m.id == "test-model-v2-pro" end)
      refute Enum.any?(result, fn m -> m.id == "test-model-v2-ultra" end)
    end

    test "applies multiple exclude patterns" do
      base = [
        %{id: "test-model-v1", provider: :test_provider_alpha},
        %{id: "test-model-old", provider: :test_provider_alpha},
        %{id: "test-model-v2-pro", provider: :test_provider_alpha},
        %{id: "legacy-model", provider: :test_provider_alpha}
      ]

      excludes = %{test_provider_alpha: ["test-model-old", "test-model-v2-*", "legacy-*"]}

      result = Merge.merge_models(base, [], excludes)

      assert length(result) == 1
      assert Enum.any?(result, fn m -> m.id == "test-model-v1" end)
    end

    test "applies excludes to multiple providers" do
      base = [
        %{id: "test-model-v1", provider: :test_provider_alpha},
        %{id: "test-model-v2-pro", provider: :test_provider_alpha},
        %{id: "test-model-beta-v2", provider: :test_provider_beta},
        %{id: "test-model-beta-v3", provider: :test_provider_beta}
      ]

      excludes = %{
        test_provider_alpha: ["test-model-v2-*"],
        test_provider_beta: ["test-model-beta-v2"]
      }

      result = Merge.merge_models(base, [], excludes)

      assert length(result) == 2
      assert Enum.any?(result, fn m -> m.id == "test-model-v1" end)
      assert Enum.any?(result, fn m -> m.id == "test-model-beta-v3" end)
    end

    test "handles empty excludes" do
      base = [%{id: "test-model-v1", provider: :test_provider_alpha}]
      result = Merge.merge_models(base, [], %{})
      assert length(result) == 1
    end

    test "handles provider not in excludes" do
      base = [
        %{id: "test-model-v1", provider: :test_provider_alpha},
        %{id: "test-model-beta-v3", provider: :test_provider_beta}
      ]

      excludes = %{test_provider_alpha: ["test-model-v2-*"]}

      result = Merge.merge_models(base, [], excludes)

      assert length(result) == 2
    end
  end

  describe "compile_pattern/1" do
    test "compiles simple glob pattern" do
      pattern = Merge.compile_pattern("test-model-v*")
      assert Regex.match?(pattern, "test-model-v1")
      assert Regex.match?(pattern, "test-model-v2")
      refute Regex.match?(pattern, "another-model-v1")
    end

    test "compiles pattern with multiple wildcards" do
      pattern = Merge.compile_pattern("test-*-*")
      assert Regex.match?(pattern, "test-model-v1")
      assert Regex.match?(pattern, "test-data-old")
      refute Regex.match?(pattern, "test-simple")
    end

    test "compiles pattern with wildcard at end" do
      pattern = Merge.compile_pattern("test-model-v2-*")
      assert Regex.match?(pattern, "test-model-v2-pro")
      assert Regex.match?(pattern, "test-model-v2-ultra")
      refute Regex.match?(pattern, "test-model-v1-pro")
    end

    test "compiles pattern with wildcard at start" do
      pattern = Merge.compile_pattern("*-turbo")
      assert Regex.match?(pattern, "test-model-v1-turbo")
      assert Regex.match?(pattern, "another-model-turbo")
      refute Regex.match?(pattern, "test-model-v1")
    end

    test "escapes regex special characters" do
      pattern = Merge.compile_pattern("model.v2+*")
      assert Regex.match?(pattern, "model.v2+beta")
      refute Regex.match?(pattern, "modelXv2Xbeta")
    end

    test "anchors pattern to start and end" do
      pattern = Merge.compile_pattern("test-model-*")
      refute Regex.match?(pattern, "prefix-test-model-v1")
      assert Regex.match?(pattern, "test-model-v1-suffix")

      pattern2 = Merge.compile_pattern("test-model-v1")
      refute Regex.match?(pattern2, "test-model-v1-suffix")
      refute Regex.match?(pattern2, "prefix-test-model-v1")
    end
  end

  describe "matches_exclude?/2" do
    test "matches exact string pattern" do
      assert Merge.matches_exclude?("test-model-old", ["test-model-old", "test-model-v1"])
      refute Merge.matches_exclude?("test-model-v2", ["test-model-old", "test-model-v1"])
    end

    test "matches regex pattern" do
      patterns = [~r/^test-model-v2-.*$/]
      assert Merge.matches_exclude?("test-model-v2-pro", patterns)
      refute Merge.matches_exclude?("test-model-v1-pro", patterns)
    end

    test "matches mixed patterns" do
      patterns = ["test-model-old", ~r/^test-model-v2-.*$/]
      assert Merge.matches_exclude?("test-model-old", patterns)
      assert Merge.matches_exclude?("test-model-v2-ultra", patterns)
      refute Merge.matches_exclude?("test-model-v1", patterns)
    end

    test "returns false for empty pattern list" do
      refute Merge.matches_exclude?("test-model-v1", [])
    end

    test "matches first matching pattern" do
      patterns = ["test-model-v1", "test-model-v2"]
      assert Merge.matches_exclude?("test-model-v1", patterns)
    end
  end

  describe "compile_excludes/1" do
    test "compiles glob patterns to regex" do
      excludes = %{test_provider_alpha: ["test-model-old", "test-model-v2-*"]}
      result = Merge.compile_excludes(excludes)

      [exact, pattern] = result.test_provider_alpha
      assert exact == "test-model-old"
      assert is_struct(pattern, Regex)
    end

    test "preserves exact patterns as strings" do
      excludes = %{test_provider_alpha: ["test-model-old", "test-model-v1"]}
      result = Merge.compile_excludes(excludes)

      assert result.test_provider_alpha == ["test-model-old", "test-model-v1"]
    end

    test "handles multiple providers" do
      excludes = %{
        test_provider_alpha: ["test-model-v2-*"],
        test_provider_beta: ["test-model-beta-v2"]
      }

      result = Merge.compile_excludes(excludes)

      assert length(result.test_provider_alpha) == 1
      assert is_struct(hd(result.test_provider_alpha), Regex)
      assert result.test_provider_beta == ["test-model-beta-v2"]
    end

    test "handles empty excludes" do
      assert Merge.compile_excludes(%{}) == %{}
    end
  end

  describe "complex nested merges" do
    test "merges complex model with capabilities, limits, and cost" do
      base = [
        %{
          id: "test-model-v1",
          provider: :test_provider_alpha,
          capabilities: %{
            chat: true,
            tools: %{enabled: true, streaming: false}
          },
          limits: %{
            context: 128_000,
            output: 4_096
          },
          cost: %{
            input: 30.0,
            output: 60.0
          }
        }
      ]

      override = [
        %{
          id: "test-model-v1",
          provider: :test_provider_alpha,
          capabilities: %{
            tools: %{streaming: true, parallel: true},
            json: %{native: true}
          },
          limits: %{
            output: 8_192
          },
          cost: %{
            cache_read: 15.0
          }
        }
      ]

      result = Merge.merge_models(base, override, %{})

      model = hd(result)
      assert model.capabilities.chat == true
      assert model.capabilities.tools.enabled == true
      assert model.capabilities.tools.streaming == true
      assert model.capabilities.tools.parallel == true
      assert model.capabilities.json.native == true
      assert model.limits.context == 128_000
      assert model.limits.output == 8_192
      assert model.cost.input == 30.0
      assert model.cost.output == 60.0
      assert model.cost.cache_read == 15.0
    end

    test "merges lists in nested structures" do
      base = [
        %{
          id: "test-model-v1",
          provider: :test_provider_alpha,
          modalities: %{
            input: [:text, :image],
            output: [:text]
          },
          tags: ["production", "stable"]
        }
      ]

      override = [
        %{
          id: "test-model-v1",
          provider: :test_provider_alpha,
          modalities: %{
            input: [:image, :audio],
            output: [:text, :json]
          },
          tags: ["stable", "recommended"]
        }
      ]

      result = Merge.merge_models(base, override, %{})

      model = hd(result)
      assert :text in model.modalities.input
      assert :image in model.modalities.input
      assert :audio in model.modalities.input
      assert :text in model.modalities.output
      assert :json in model.modalities.output
      assert "production" in model.tags
      assert "stable" in model.tags
      assert "recommended" in model.tags
    end
  end

  describe "edge cases" do
    test "handles nil in nested maps" do
      base = %{config: nil}
      override = %{config: %{value: 1}}

      result = Merge.merge(base, override, :higher)

      assert result == %{config: %{value: 1}}
    end

    test "handles models with missing provider or id" do
      base = [
        %{id: "test-model-v1"},
        %{provider: :test_provider_alpha}
      ]

      override = []

      result = Merge.merge_models(base, override, %{})

      assert length(result) == 2
    end

    test "handles wildcard matching empty string" do
      pattern = Merge.compile_pattern("*")
      assert Regex.match?(pattern, "")
      assert Regex.match?(pattern, "anything")
    end

    test "merges with atom keys and string keys separately" do
      base = %{"value" => 2, value: 1}
      override = %{value: 10}

      result = Merge.merge(base, override, :higher)

      assert result.value == 10
      assert result["value"] == 2
    end
  end
end
