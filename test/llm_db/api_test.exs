defmodule LLMDB.APITest do
  use ExUnit.Case, async: false

  alias LLMDB.Store

  setup do
    Store.clear!()
    Application.delete_env(:llm_db, :allow)
    Application.delete_env(:llm_db, :deny)
    Application.delete_env(:llm_db, :prefer)
    Application.delete_env(:llm_db, :filter)

    # Load minimal test data
    providers = [
      %{id: :openai, name: "OpenAI"},
      %{id: :anthropic, name: "Anthropic"},
      %{id: :cohere, name: "Cohere"}
    ]

    # Models need to be normalized (provider as atom)
    models = [
      %{
        id: "gpt-4o",
        provider: :openai,
        extra: %{
          llmfit: %{
            parameters_raw: 100_000_000_000,
            memory: %{min_ram_gb: 60.0, min_vram_gb: 50.0}
          }
        },
        capabilities: %{chat: true, tools: %{enabled: true}, json: %{native: true}}
      },
      %{
        id: "gpt-4o-mini",
        provider: :openai,
        extra: %{
          llmfit: %{
            parameters_raw: 10_000_000_000,
            memory: %{min_ram_gb: 6.0, min_vram_gb: 5.0}
          }
        },
        capabilities: %{chat: true, tools: %{enabled: true}, json: %{native: true}}
      },
      %{
        id: "claude-3-5-sonnet-20241022",
        provider: :anthropic,
        extra: %{
          "llmfit" => %{
            "parameters_raw" => 200_000_000_000,
            "memory" => %{"min_ram_gb" => 120.0, "min_vram_gb" => 100.0},
            "moe" => %{"active_parameters" => 20_000_000_000}
          }
        },
        capabilities: %{chat: true, tools: %{enabled: true}, json: %{native: false}}
      },
      %{
        id: "rerank-v3.5",
        provider: :cohere,
        capabilities: %{chat: false, rerank: true, streaming: %{text: false}}
      }
    ]

    app_config = LLMDB.Config.get()
    provider_ids = Enum.map(providers, & &1.id)

    {filters, _unknown_info} =
      LLMDB.Config.compile_filters(app_config.allow, app_config.deny, provider_ids)

    filtered_models = LLMDB.Engine.apply_filters(models, filters)

    snapshot = %{
      providers_by_id: Map.new(providers, &{&1.id, &1}),
      models_by_key: Map.new(filtered_models, &{{&1.provider, &1.id}, &1}),
      aliases_by_key: build_aliases_index(filtered_models),
      providers: providers,
      models: Enum.group_by(filtered_models, & &1.provider),
      base_models: models,
      filters: filters,
      prefer: app_config.prefer,
      meta: %{
        epoch: nil,
        generated_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }
    }

    Store.put!(snapshot, [])
    :ok
  end

  describe "providers/0" do
    test "returns all providers as list" do
      providers = LLMDB.providers()

      assert is_list(providers)
      assert length(providers) == 3
      assert Enum.all?(providers, &match?(%LLMDB.Provider{}, &1))
      assert Enum.map(providers, & &1.id) |> Enum.sort() == [:anthropic, :cohere, :openai]
    end
  end

  describe "models/0" do
    test "returns all models as list" do
      models = LLMDB.models()

      assert is_list(models)
      assert length(models) == 4
      assert Enum.all?(models, &match?(%LLMDB.Model{}, &1))
    end
  end

  describe "models/1" do
    test "returns models for specific provider" do
      openai_models = LLMDB.models(:openai)

      assert is_list(openai_models)
      assert length(openai_models) == 2
      assert Enum.all?(openai_models, &(&1.provider == :openai))

      anthropic_models = LLMDB.models(:anthropic)
      assert length(anthropic_models) == 1
      assert hd(anthropic_models).provider == :anthropic

      cohere_models = LLMDB.models(:cohere)
      assert length(cohere_models) == 1
      assert hd(cohere_models).provider == :cohere
    end

    test "returns empty list for unknown provider" do
      assert LLMDB.models(:unknown) == []
    end
  end

  describe "model/1" do
    test "accepts each documented qualified lookup form" do
      assert {:ok, colon_model} = LLMDB.model("openai:gpt-4o")
      assert {:ok, ^colon_model} = LLMDB.model("gpt-4o@openai")
      assert {:ok, ^colon_model} = LLMDB.model({:openai, "gpt-4o"})
      assert {:ok, ^colon_model} = LLMDB.model({"openai", "gpt-4o"})
    end

    test "normalizes string providers and preserves lookup errors" do
      assert {:ok, model} = LLMDB.model({"openai", "gpt-4o-mini"})
      assert model.provider == :openai

      assert {:error, :not_found} = LLMDB.model({:openai, "missing"})
      assert {:error, :unknown_provider} = LLMDB.model({"missing-provider", "missing"})
    end
  end

  describe "candidates/1" do
    test "returns all matching models in preference order" do
      candidates = LLMDB.candidates(require: [chat: true])

      assert is_list(candidates)
      assert length(candidates) >= 3
      assert Enum.all?(candidates, &match?({_provider, _model_id}, &1))
    end

    test "filters by required capabilities" do
      candidates = LLMDB.candidates(require: [chat: true, json_native: true])

      assert is_list(candidates)
      # Only OpenAI models have json.native: true in our test data
      assert Enum.all?(candidates, fn {provider, _id} -> provider == :openai end)
    end

    test "respects prefer option" do
      candidates = LLMDB.candidates(require: [chat: true], prefer: [:anthropic])

      # First result should be from anthropic if available
      assert match?({:anthropic, _}, hd(candidates))
    end

    test "respects scope option" do
      candidates = LLMDB.candidates(require: [chat: true], scope: :openai)

      assert length(candidates) == 2
      assert Enum.all?(candidates, fn {provider, _id} -> provider == :openai end)
    end

    test "respects forbid option" do
      candidates = LLMDB.candidates(require: [chat: true], forbid: [json_native: true])

      # Should exclude OpenAI models which have json_native: true
      refute Enum.any?(candidates, fn {provider, _id} -> provider == :openai end)
    end

    test "returns empty list when no matches" do
      candidates = LLMDB.candidates(require: [embeddings: true])

      assert candidates == []
    end

    test "filters by rerank capability" do
      candidates = LLMDB.candidates(require: [rerank: true])

      assert candidates == [{:cohere, "rerank-v3.5"}]
    end

    test "sorts by total parameters and places missing values last" do
      assert LLMDB.candidates(sort_by: :total_parameters) == [
               {:openai, "gpt-4o-mini"},
               {:openai, "gpt-4o"},
               {:anthropic, "claude-3-5-sonnet-20241022"},
               {:cohere, "rerank-v3.5"}
             ]

      assert LLMDB.candidates(sort_by: :total_parameters, sort_order: :desc) == [
               {:anthropic, "claude-3-5-sonnet-20241022"},
               {:openai, "gpt-4o"},
               {:openai, "gpt-4o-mini"},
               {:cohere, "rerank-v3.5"}
             ]
    end

    test "sorts by active parameters with snapshot string keys" do
      assert hd(LLMDB.candidates(sort_by: :active_parameters)) ==
               {:anthropic, "claude-3-5-sonnet-20241022"}
    end

    test "sorts by minimum RAM and VRAM" do
      assert Enum.take(LLMDB.candidates(sort_by: :minimum_ram_gb), 3) == [
               {:openai, "gpt-4o-mini"},
               {:openai, "gpt-4o"},
               {:anthropic, "claude-3-5-sonnet-20241022"}
             ]

      assert Enum.take(LLMDB.candidates(sort_by: :minimum_vram_gb), 3) == [
               {:openai, "gpt-4o-mini"},
               {:openai, "gpt-4o"},
               {:anthropic, "claude-3-5-sonnet-20241022"}
             ]
    end

    test "selects the first sorted model" do
      assert {:ok, {:openai, "gpt-4o-mini"}} =
               LLMDB.select(sort_by: :total_parameters)
    end

    test "rejects invalid sort options" do
      assert_raise ArgumentError, ~r/sort_by must be/, fn ->
        LLMDB.candidates(sort_by: :unknown_size)
      end

      assert_raise ArgumentError, ~r/sort_order must be/, fn ->
        LLMDB.candidates(sort_order: :sideways)
      end
    end
  end

  describe "parse/1" do
    test "parses valid spec string" do
      assert {:ok, {:openai, "gpt-4o"}} = LLMDB.parse("openai:gpt-4o")

      assert {:ok, {:anthropic, "claude-3-5-sonnet-20241022"}} =
               LLMDB.parse("anthropic:claude-3-5-sonnet-20241022")
    end

    test "accepts tuple format" do
      assert {:ok, {:openai, "gpt-4o"}} = LLMDB.parse({:openai, "gpt-4o"})
    end

    test "returns error for invalid format" do
      assert {:error, _} = LLMDB.parse("invalid")
      assert {:error, _} = LLMDB.parse("no-colon")
    end
  end

  describe "allowed?/1 with alias resolution" do
    setup do
      # Add a model with an alias to test alias resolution
      # We need to bypass filtering to keep the model in the catalog
      Store.clear!()

      on_exit(fn ->
        Application.delete_env(:llm_db, :filter)
      end)

      providers = [%{id: :openai, name: "OpenAI"}]

      models = [
        %{
          id: "gpt-4o",
          provider: :openai,
          aliases: ["gpt-4-omni"],
          capabilities: %{chat: true}
        }
      ]

      # Set deny filter to deny the canonical ID
      app_config = %{
        allow: :all,
        deny: %{openai: ["gpt-4o"]},
        prefer: []
      }

      provider_ids = Enum.map(providers, & &1.id)

      {filters, _unknown_info} =
        LLMDB.Config.compile_filters(app_config.allow, app_config.deny, provider_ids)

      # Apply filters - model should be filtered out
      filtered_models = LLMDB.Engine.apply_filters(models, filters)

      snapshot = %{
        providers_by_id: Map.new(providers, &{&1.id, &1}),
        models_by_key: Map.new(filtered_models, &{{&1.provider, &1.id}, &1}),
        aliases_by_key: build_aliases_index(filtered_models),
        providers: providers,
        models: Enum.group_by(filtered_models, & &1.provider),
        base_models: models,
        filters: filters,
        prefer: app_config.prefer,
        meta: %{
          epoch: nil,
          generated_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }
      }

      Store.put!(snapshot, [])
      :ok
    end

    test "resolves aliases when checking allowed" do
      # Both the alias and canonical ID should be denied (filtered out at load time)
      refute LLMDB.allowed?({:openai, "gpt-4-omni"})
      refute LLMDB.allowed?({:openai, "gpt-4o"})
    end
  end

  defp build_aliases_index(models) do
    models
    |> Enum.flat_map(fn model ->
      provider = model.provider
      canonical_id = model.id
      aliases = Map.get(model, :aliases, [])

      Enum.map(aliases, fn alias_name ->
        {{provider, alias_name}, canonical_id}
      end)
    end)
    |> Map.new()
  end
end
