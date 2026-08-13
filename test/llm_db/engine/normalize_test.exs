defmodule LLMDB.Engine.NormalizeTest do
  use ExUnit.Case, async: true

  alias LLMDB.Normalize

  doctest Normalize

  describe "normalize_provider_id/1" do
    test "converts binary provider ID with hyphens to atom with underscores" do
      assert {:ok, :google_vertex} =
               Normalize.normalize_provider_id("google-vertex", unsafe: true)

      assert {:ok, :azure_openai} = Normalize.normalize_provider_id("azure-openai", unsafe: true)

      assert {:ok, :anthropic_vertex} =
               Normalize.normalize_provider_id("anthropic-vertex", unsafe: true)
    end

    test "converts binary provider ID with dots to atom with underscores" do
      assert {:ok, :wafer_ai} = Normalize.normalize_provider_id("wafer.ai", unsafe: true)

      assert {:ok, :vendor_api_proxy} =
               Normalize.normalize_provider_id("vendor.api-proxy", unsafe: true)
    end

    test "converts binary provider ID with underscores to atom" do
      assert {:ok, :google_vertex} =
               Normalize.normalize_provider_id("google_vertex", unsafe: true)

      assert {:ok, :some_provider} =
               Normalize.normalize_provider_id("some_provider", unsafe: true)
    end

    test "converts simple binary provider ID to atom" do
      assert {:ok, :test_alpha} = Normalize.normalize_provider_id("test_alpha", unsafe: true)
      assert {:ok, :test_beta} = Normalize.normalize_provider_id("test_beta", unsafe: true)
      assert {:ok, :test_gamma} = Normalize.normalize_provider_id("test_gamma", unsafe: true)
    end

    test "passes through already-atom providers unchanged" do
      assert {:ok, :openai} = Normalize.normalize_provider_id(:openai)
      assert {:ok, :google_vertex} = Normalize.normalize_provider_id(:google_vertex)
      assert {:ok, :some_atom} = Normalize.normalize_provider_id(:some_atom)
    end

    test "returns error for invalid provider strings" do
      assert {:error, :bad_provider} = Normalize.normalize_provider_id("")
      assert {:error, :bad_provider} = Normalize.normalize_provider_id("has spaces")
      assert {:error, :bad_provider} = Normalize.normalize_provider_id("has@special")
    end

    test "does not create atoms for unknown provider strings" do
      provider_id = "normalize_unknown_provider_#{System.unique_integer([:positive])}"

      assert_raise ArgumentError, fn -> String.to_existing_atom(provider_id) end
      assert {:error, :unknown_provider} = Normalize.normalize_provider_id(provider_id)
      assert_raise ArgumentError, fn -> String.to_existing_atom(provider_id) end
    end

    test "returns error for excessively long strings" do
      long_string = String.duplicate("a", 300)
      assert {:error, :bad_provider} = Normalize.normalize_provider_id(long_string)
    end

    test "returns error for non-binary, non-atom types" do
      assert {:error, :bad_provider} = Normalize.normalize_provider_id(123)
      assert {:error, :bad_provider} = Normalize.normalize_provider_id([])
      assert {:error, :bad_provider} = Normalize.normalize_provider_id(%{})
    end

    test "handles mixed case provider IDs" do
      assert {:ok, :OpenAI} = Normalize.normalize_provider_id("OpenAI", unsafe: true)

      assert {:ok, :Google_Vertex} =
               Normalize.normalize_provider_id("Google-Vertex", unsafe: true)
    end

    test "handles alphanumeric provider IDs" do
      assert {:ok, :provider123} = Normalize.normalize_provider_id("provider123", unsafe: true)
      assert {:ok, :abc_123_xyz} = Normalize.normalize_provider_id("abc-123-xyz", unsafe: true)
    end
  end

  describe "normalize_model_identity/1" do
    test "extracts provider and id from model map with binary provider" do
      model = %{provider: "test-provider-alpha", id: "test-model-pro"}

      assert {:ok, {:test_provider_alpha, "test-model-pro"}} =
               Normalize.normalize_model_identity(model)
    end

    test "extracts provider and id from model map with atom provider" do
      model = %{provider: :test_provider_alpha, id: "test-model-v1"}

      assert {:ok, {:test_provider_alpha, "test-model-v1"}} =
               Normalize.normalize_model_identity(model)
    end

    test "handles provider with underscores" do
      model = %{provider: "test_provider_beta", id: "test-model-v2"}

      assert {:ok, {:test_provider_beta, "test-model-v2"}} =
               Normalize.normalize_model_identity(model, unsafe: true)
    end

    test "returns error when id is missing" do
      model = %{provider: "test-provider"}
      assert {:error, :missing_id} = Normalize.normalize_model_identity(model)
    end

    test "returns error when provider is missing" do
      model = %{id: "test-model"}
      assert {:error, :missing_provider} = Normalize.normalize_model_identity(model)
    end

    test "returns error when both provider and id are missing" do
      model = %{name: "Some Model"}
      assert {:error, :invalid_model} = Normalize.normalize_model_identity(model)
    end

    test "returns error for invalid provider" do
      model = %{provider: "invalid@provider", id: "model-1"}
      assert {:error, :bad_provider} = Normalize.normalize_model_identity(model)
    end

    test "returns error when id is not a string" do
      model = %{provider: "test-provider", id: 123}
      assert {:error, :invalid_id} = Normalize.normalize_model_identity(model)
    end

    test "handles complex model IDs" do
      model = %{provider: "test-provider-alpha", id: "test-model-v3-advanced-20240229"}

      assert {:ok, {:test_provider_alpha, "test-model-v3-advanced-20240229"}} =
               Normalize.normalize_model_identity(model)
    end
  end

  describe "normalize_date/1" do
    test "returns nil for nil input" do
      assert nil == Normalize.normalize_date(nil)
    end

    test "returns empty string for empty string" do
      assert "" == Normalize.normalize_date("")
    end

    test "keeps already normalized dates unchanged" do
      assert "2024-01-15" == Normalize.normalize_date("2024-01-15")
      assert "2023-12-31" == Normalize.normalize_date("2023-12-31")
      assert "2025-06-01" == Normalize.normalize_date("2025-06-01")
    end

    test "normalizes dates with forward slashes" do
      assert "2024-01-15" == Normalize.normalize_date("2024/01/15")
      assert "2023-12-31" == Normalize.normalize_date("2023/12/31")
    end

    test "normalizes dates with single-digit months and days" do
      assert "2024-01-05" == Normalize.normalize_date("2024-1-5")
      assert "2024-03-09" == Normalize.normalize_date("2024-3-9")
    end

    test "leaves invalid dates as-is" do
      assert "invalid-date" == Normalize.normalize_date("invalid-date")
      assert "2024-13-01" == Normalize.normalize_date("2024-13-01")
      assert "2024-00-15" == Normalize.normalize_date("2024-00-15")
      assert "2024-01-32" == Normalize.normalize_date("2024-01-32")
      assert "not-a-date" == Normalize.normalize_date("not-a-date")
    end

    test "leaves malformed date strings as-is" do
      assert "2024" == Normalize.normalize_date("2024")
      assert "2024-01" == Normalize.normalize_date("2024-01")
      assert "24-01-15" == Normalize.normalize_date("24-01-15")
    end

    test "handles dates with text" do
      assert "2024-01-15 extra text" == Normalize.normalize_date("2024-01-15 extra text")
    end

    test "normalizes years with proper padding" do
      assert "1000-01-01" == Normalize.normalize_date("1000-1-1")
      assert "9999-12-31" == Normalize.normalize_date("9999-12-31")
    end

    test "leaves dates outside valid year range as-is" do
      assert "999-01-01" == Normalize.normalize_date("999-01-01")
      assert "10000-01-01" == Normalize.normalize_date("10000-01-01")
    end
  end

  describe "normalize_providers/1" do
    test "normalizes list of provider maps" do
      providers = [
        %{id: "test-provider-alpha", name: "Test Provider Alpha"},
        %{id: :test_provider_beta, name: "Test Provider Beta"},
        %{id: "test-provider-gamma", name: "Test Provider Gamma"}
      ]

      normalized = Normalize.normalize_providers(providers)

      assert [
               %{id: :test_provider_alpha, name: "Test Provider Alpha"},
               %{id: :test_provider_beta, name: "Test Provider Beta"},
               %{id: :test_provider_gamma, name: "Test Provider Gamma"}
             ] = normalized
    end

    test "handles empty list" do
      assert [] = Normalize.normalize_providers([])
    end

    test "preserves provider maps without id" do
      providers = [
        %{name: "Some Provider"},
        %{id: "test-provider", name: "Test Provider"}
      ]

      normalized = Normalize.normalize_providers(providers)

      assert [
               %{name: "Some Provider"},
               %{id: :test_provider, name: "Test Provider"}
             ] = normalized
    end

    test "keeps invalid provider IDs unchanged" do
      providers = [
        %{id: "valid-provider"},
        %{id: "invalid@provider"}
      ]

      normalized = Normalize.normalize_providers(providers)

      assert [
               %{id: :valid_provider},
               %{id: "invalid@provider"}
             ] = normalized
    end

    test "preserves all other fields in provider maps" do
      providers = [
        %{
          id: "test-provider-alpha",
          name: "Test Provider Alpha",
          base_url: "https://alpha.example.com",
          env: ["TEST_API_KEY"],
          extra: %{some: "data"}
        }
      ]

      normalized = Normalize.normalize_providers(providers)

      assert [
               %{
                 id: :test_provider_alpha,
                 name: "Test Provider Alpha",
                 base_url: "https://alpha.example.com",
                 env: ["TEST_API_KEY"],
                 extra: %{some: "data"}
               }
             ] = normalized
    end
  end

  describe "normalize_models/1" do
    test "normalizes list of model maps" do
      models = [
        %{provider: "test-provider-alpha", id: "test-model-pro"},
        %{provider: :test_provider_beta, id: "test-model-v1"},
        %{provider: "test-provider-gamma", id: "test-model-v2"}
      ]

      normalized = Normalize.normalize_models(models)

      assert [
               %{provider: :test_provider_alpha, id: "test-model-pro"},
               %{provider: :test_provider_beta, id: "test-model-v1"},
               %{provider: :test_provider_gamma, id: "test-model-v2"}
             ] = normalized
    end

    test "handles empty list" do
      assert [] = Normalize.normalize_models([])
    end

    test "preserves model maps without provider" do
      models = [
        %{id: "some-model"},
        %{provider: "test-provider", id: "test-model"}
      ]

      normalized = Normalize.normalize_models(models)

      assert [
               %{id: "some-model"},
               %{provider: :test_provider, id: "test-model"}
             ] = normalized
    end

    test "keeps invalid provider IDs unchanged" do
      models = [
        %{provider: "valid-provider", id: "model-1"},
        %{provider: "invalid@provider", id: "model-2"}
      ]

      normalized = Normalize.normalize_models(models)

      assert [
               %{provider: :valid_provider, id: "model-1"},
               %{provider: "invalid@provider", id: "model-2"}
             ] = normalized
    end

    test "preserves all other fields in model maps" do
      models = [
        %{
          provider: "test-provider-alpha",
          id: "test-model-pro",
          name: "Test Model Pro",
          family: "test-model",
          release_date: "2024-01-15",
          capabilities: %{chat: true},
          tags: ["production"],
          extra: %{some: "data"}
        }
      ]

      normalized = Normalize.normalize_models(models)

      assert [
               %{
                 provider: :test_provider_alpha,
                 id: "test-model-pro",
                 name: "Test Model Pro",
                 family: "test-model",
                 release_date: "2024-01-15",
                 capabilities: %{chat: true},
                 tags: ["production"],
                 extra: %{some: "data"}
               }
             ] = normalized
    end
  end

  describe "lifecycle normalization" do
    test "lifecycle.status 'retired' sets both deprecated and retired to true" do
      models = [
        %{
          provider: :openai,
          id: "old-model",
          lifecycle: %{status: "retired"}
        }
      ]

      [normalized] = Normalize.normalize_models(models)

      assert normalized.deprecated == true
      assert normalized.retired == true
      assert normalized.lifecycle.status == "retired"
    end

    test "lifecycle.status 'deprecated' sets deprecated true, retired false" do
      models = [
        %{
          provider: :openai,
          id: "old-model",
          lifecycle: %{status: "deprecated", replacement: "new-model"}
        }
      ]

      [normalized] = Normalize.normalize_models(models)

      assert normalized.deprecated == true
      assert normalized.retired == false
      assert normalized.lifecycle.status == "deprecated"
      assert normalized.lifecycle.replacement == "new-model"
    end

    test "lifecycle.status 'active' sets both booleans to false" do
      models = [
        %{
          provider: :openai,
          id: "new-model",
          lifecycle: %{status: "active"}
        }
      ]

      [normalized] = Normalize.normalize_models(models)

      assert normalized.deprecated == false
      assert normalized.retired == false
    end

    test "lifecycle.status overrides conflicting boolean flags" do
      models = [
        %{
          provider: :openai,
          id: "model",
          deprecated: false,
          lifecycle: %{status: "deprecated"}
        }
      ]

      [normalized] = Normalize.normalize_models(models)

      assert normalized.deprecated == true
      assert normalized.retired == false
    end

    test "deprecated: true derives lifecycle.status 'deprecated'" do
      models = [
        %{
          provider: :openai,
          id: "old-model",
          deprecated: true
        }
      ]

      [normalized] = Normalize.normalize_models(models)

      assert normalized.deprecated == true
      assert normalized.retired == false
      assert normalized.lifecycle.status == "deprecated"
    end

    test "retired: true derives lifecycle.status 'retired' and sets deprecated" do
      models = [
        %{
          provider: :openai,
          id: "old-model",
          retired: true
        }
      ]

      [normalized] = Normalize.normalize_models(models)

      assert normalized.deprecated == true
      assert normalized.retired == true
      assert normalized.lifecycle.status == "retired"
    end

    test "no lifecycle or booleans leaves model unchanged" do
      models = [
        %{
          provider: :openai,
          id: "model"
        }
      ]

      [normalized] = Normalize.normalize_models(models)

      refute Map.has_key?(normalized, :deprecated)
      refute Map.has_key?(normalized, :retired)
      refute Map.has_key?(normalized, :lifecycle)
    end

    test "non-map lifecycle is treated as nil and does not crash" do
      models = [
        %{
          provider: :openai,
          id: "model",
          lifecycle: "invalid",
          deprecated: true
        }
      ]

      [normalized] = Normalize.normalize_models(models)

      assert normalized.deprecated == true
      assert normalized.lifecycle.status == "deprecated"
    end

    test "idempotent - normalizing twice produces same result" do
      models = [
        %{
          provider: :openai,
          id: "model",
          lifecycle: %{status: "deprecated", replacement: "new-model"}
        }
      ]

      [first] = Normalize.normalize_models(models)
      [second] = Normalize.normalize_models([first])

      assert first.deprecated == second.deprecated
      assert first.retired == second.retired
      assert first.lifecycle.status == second.lifecycle.status
    end

    test "issue #99 - deprecated flag matches lifecycle status" do
      models = [
        %{
          provider: :openai,
          id: "dall-e-3",
          lifecycle: %{
            status: "deprecated",
            deprecated_at: "2025-05-12",
            retires_at: "2026-05-12",
            replacement: "gpt-image-1.5"
          }
        }
      ]

      [normalized] = Normalize.normalize_models(models)

      assert normalized.lifecycle.status == "deprecated"
      assert normalized.deprecated == true
    end
  end
end
