defmodule LLMDBTest do
  use ExUnit.Case, async: false

  alias LLMDB.Store

  setup do
    reset_test_state!()
    on_exit(&reset_test_state!/0)
    :ok
  end

  defp reset_test_state! do
    Store.clear!()

    Application.delete_env(:llm_db, :allow)
    Application.delete_env(:llm_db, :deny)
    Application.delete_env(:llm_db, :prefer)
    Application.delete_env(:llm_db, :filter)
  end

  # Helper to load test data directly via Engine (bypassing packaged snapshot)
  defp load_with_test_data(config) when is_map(config) do
    # Extract test data
    providers = get_in(config, [:overrides, :providers]) || []
    models = get_in(config, [:overrides, :models]) || []

    # Set application env for filter (if provided as old format, convert)
    if Map.has_key?(config, :allow) or Map.has_key?(config, :deny) do
      Application.put_env(:llm_db, :filter, %{
        allow: Map.get(config, :allow, :all),
        deny: Map.get(config, :deny, %{})
      })
    end

    if Map.has_key?(config, :prefer), do: Application.put_env(:llm_db, :prefer, config.prefer)

    # Get config with test filters
    app_config = LLMDB.Config.get()

    # Compile filters (returns {filters, unknown: []})
    provider_ids = Enum.map(providers, & &1.id)

    {filters, _unknown_info} =
      LLMDB.Config.compile_filters(app_config.allow, app_config.deny, provider_ids)

    # Apply filters
    filtered_models = LLMDB.Engine.apply_filters(models, filters)

    # Build snapshot with inline indexes
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

    # Store snapshot
    Store.put!(snapshot, [])
    {:ok, snapshot}
  end

  # Minimal test data for basic tests
  defp minimal_test_data do
    %{
      providers: [%{id: :test_provider, name: "Test Provider"}],
      models: [
        %{id: "test-model", provider: :test_provider, capabilities: %{chat: true}}
      ]
    }
  end

  describe "lifecycle functions" do
    test "load/1 runs engine and stores snapshot" do
      {:ok, snapshot} = load_with_test_data(%{overrides: minimal_test_data()})

      assert is_map(snapshot)
      assert Map.has_key?(snapshot, :providers_by_id)
      assert Map.has_key?(snapshot, :models_by_key)
      assert Map.has_key?(snapshot, :aliases_by_key)
      assert Map.has_key?(snapshot, :models)
      assert Map.has_key?(snapshot, :filters)
      assert Map.has_key?(snapshot, :meta)

      assert Store.snapshot() == snapshot
    end

    test "reload/0 uses last opts" do
      {:ok, _} = load_with_test_data(%{overrides: minimal_test_data()})
      epoch1 = LLMDB.epoch()

      # reload is just calling load again
      {:ok, _} = LLMDB.load()
      epoch2 = LLMDB.epoch()

      assert epoch2 > epoch1
    end

    test "snapshot/0 returns current snapshot" do
      {:ok, snapshot} = load_with_test_data(%{overrides: minimal_test_data()})
      assert LLMDB.snapshot() == snapshot
    end

    test "snapshot/0 returns nil when not loaded" do
      assert LLMDB.snapshot() == nil
    end

    test "epoch/0 returns current epoch" do
      {:ok, _} = load_with_test_data(%{overrides: minimal_test_data()})
      epoch = LLMDB.epoch()

      assert is_integer(epoch)
      assert epoch > 0
    end

    test "epoch/0 returns 0 when not loaded" do
      assert LLMDB.epoch() == 0
    end
  end

  describe "provider listing and lookup" do
    setup do
      {:ok, _} = load_with_test_data(%{overrides: minimal_test_data()})
      :ok
    end

    test "provider/0 returns sorted provider structs" do
      providers = LLMDB.providers()

      assert is_list(providers)
      refute Enum.empty?(providers)
      assert Enum.all?(providers, &is_struct(&1, LLMDB.Provider))
      provider_ids = Enum.map(providers, & &1.id)
      assert provider_ids == Enum.sort(provider_ids)
    end

    test "provider/0 returns empty list when not loaded" do
      Store.clear!()
      assert LLMDB.providers() == []
    end

    test "provider/1 returns provider metadata" do
      providers = LLMDB.providers()
      provider_id = hd(providers).id

      {:ok, provider_data} = LLMDB.provider(provider_id)

      assert is_struct(provider_data, LLMDB.Provider)
      assert provider_data.id == provider_id
    end

    test "provider/1 returns :error for unknown provider" do
      assert {:error, :not_found} = LLMDB.provider(:nonexistent)
    end

    test "provider/1 returns :error when not loaded" do
      Store.clear!()
      assert {:error, :not_found} = LLMDB.provider(:openai)
    end
  end

  describe "model listing with filters" do
    setup do
      {:ok, _} = load_with_test_data(%{overrides: minimal_test_data()})
      :ok
    end

    test "models/1 returns all models for provider" do
      providers = LLMDB.providers()

      if providers != [] do
        provider_id = hd(providers).id
        models = LLMDB.models(provider_id)

        assert is_list(models)
        assert Enum.all?(models, &is_struct(&1, LLMDB.Model))
        assert Enum.all?(models, fn m -> m.provider == provider_id end)
      end
    end

    test "models/1 with manual filtering by required capabilities" do
      providers = LLMDB.providers()

      if providers != [] do
        provider_id = hd(providers).id

        models =
          LLMDB.models(provider_id)
          |> Enum.filter(fn model ->
            caps = model.capabilities
            caps.chat == true
          end)

        assert is_list(models)

        Enum.each(models, fn model ->
          assert model.capabilities.chat == true
        end)
      end
    end

    test "models/1 with manual filtering by forbidden capabilities" do
      providers = LLMDB.providers()

      if providers != [] do
        provider_id = hd(providers).id

        models =
          LLMDB.models(provider_id)
          |> Enum.filter(fn model ->
            caps = model.capabilities
            not (Map.get(caps, :embeddings) == true)
          end)

        assert is_list(models)

        Enum.each(models, fn model ->
          caps = model.capabilities
          refute Map.get(caps, :embeddings) == true
        end)
      end
    end

    test "models/1 with manual filtering combining require and forbid" do
      providers = LLMDB.providers()

      if providers != [] do
        provider_id = hd(providers).id

        models =
          LLMDB.models(provider_id)
          |> Enum.filter(fn model ->
            caps = model.capabilities
            caps.chat == true and not (Map.get(caps, :embeddings) == true)
          end)

        assert is_list(models)

        Enum.each(models, fn model ->
          caps = model.capabilities
          assert caps.chat == true
          refute Map.get(caps, :embeddings) == true
        end)
      end
    end

    test "models/1 returns empty list when not loaded" do
      Store.clear!()
      assert LLMDB.models(:openai) == []
    end
  end

  describe "model lookup" do
    setup do
      {:ok, _} = load_with_test_data(%{overrides: minimal_test_data()})
      :ok
    end

    test "model/2 returns model by provider and id" do
      providers = LLMDB.providers()

      if providers != [] do
        provider_id = hd(providers).id
        models = LLMDB.models(provider_id)

        if models != [] do
          model_data = hd(models)
          {:ok, fetched} = LLMDB.model(provider_id, model_data.id)

          assert is_struct(fetched, LLMDB.Model)
          assert fetched.id == model_data.id
          assert fetched.provider == provider_id
        end
      end
    end

    test "model/2 resolves aliases" do
      providers = LLMDB.providers()

      if providers != [] do
        provider_id = hd(providers).id
        models = LLMDB.models(provider_id)

        model_with_alias = Enum.find(models, fn m -> m.aliases != [] end)

        if model_with_alias do
          alias_name = hd(model_with_alias.aliases)
          {:ok, fetched} = LLMDB.model(provider_id, alias_name)

          assert fetched.id == model_with_alias.id
        end
      end
    end

    test "model/2 returns :error for unknown model" do
      assert {:error, :not_found} = LLMDB.model(:openai, "nonexistent-model")
    end

    test "model/2 returns :error when not loaded" do
      Store.clear!()
      assert {:error, :not_found} = LLMDB.model(:openai, "gpt-4")
    end
  end

  describe "capabilities/1" do
    setup do
      {:ok, _} = load_with_test_data(%{overrides: minimal_test_data()})
      :ok
    end

    test "capabilities/1 with tuple spec returns capabilities or nil" do
      providers = LLMDB.providers()

      if providers != [] do
        provider_id = hd(providers).id
        models = LLMDB.models(provider_id)

        if models != [] do
          model_data = hd(models)
          caps = LLMDB.capabilities({provider_id, model_data.id})

          # Capabilities may be nil if not in snapshot
          if caps do
            assert is_map(caps)
          end
        end
      end
    end

    test "capabilities/1 with string spec returns capabilities or nil" do
      providers = LLMDB.providers()

      if providers != [] do
        provider_id = hd(providers).id
        models = LLMDB.models(provider_id)

        if models != [] do
          model_data = hd(models)
          spec = "#{provider_id}:#{model_data.id}"
          caps = LLMDB.capabilities(spec)

          # Capabilities may be nil if not in snapshot
          if caps do
            assert is_map(caps)
          end
        end
      end
    end

    test "capabilities/1 returns nil for unknown model" do
      assert LLMDB.capabilities({:openai, "nonexistent"}) == nil
    end

    test "capabilities/1 returns nil when not loaded" do
      Store.clear!()
      assert LLMDB.capabilities({:openai, "gpt-4"}) == nil
    end
  end

  describe "allowed?/1" do
    test "allowed?/1 returns true for allowed model with :all filter" do
      config = %{
        overrides: %{
          providers: [%{id: :test_provider}],
          models: [
            %{id: "test-model", provider: :test_provider, capabilities: %{chat: true}}
          ],
          exclude: %{}
        },
        overrides_module: nil,
        allow: :all,
        deny: %{},
        prefer: []
      }

      {:ok, _} = load_with_test_data(config)

      assert LLMDB.allowed?({:test_provider, "test-model"}) == true
    end

    test "allowed?/1 returns false for denied model" do
      config = %{
        overrides: %{
          providers: [%{id: :test_provider}],
          models: [
            %{id: "test-model", provider: :test_provider, capabilities: %{chat: true}},
            %{id: "other-model", provider: :test_provider, capabilities: %{chat: true}}
          ],
          exclude: %{}
        },
        overrides_module: nil,
        allow: :all,
        deny: %{test_provider: ["test-model"]},
        prefer: []
      }

      {:ok, _} = load_with_test_data(config)

      assert LLMDB.allowed?({:test_provider, "test-model"}) == false
      assert LLMDB.allowed?({:test_provider, "other-model"}) == true
    end

    test "allowed?/1 with string spec" do
      config = %{
        overrides: %{
          providers: [%{id: :test_provider}],
          models: [
            %{id: "test-model", provider: :test_provider, capabilities: %{chat: true}}
          ],
          exclude: %{}
        },
        overrides_module: nil,
        allow: :all,
        deny: %{},
        prefer: []
      }

      {:ok, _} = load_with_test_data(config)

      assert LLMDB.allowed?("test_provider:test-model") == true
    end

    test "allowed?/1 returns false when not loaded" do
      Store.clear!()
      assert LLMDB.allowed?({:openai, "gpt-4"}) == false
    end
  end

  describe "select/1" do
    test "select/1 returns first matching model" do
      config = %{
        overrides: %{
          providers: [%{id: :provider_a}, %{id: :provider_b}],
          models: [
            %{
              id: "model-a1",
              provider: :provider_a,
              capabilities: %{chat: true, tools: %{enabled: true}}
            },
            %{
              id: "model-b1",
              provider: :provider_b,
              capabilities: %{chat: true, tools: %{enabled: true}}
            }
          ],
          exclude: %{}
        },
        overrides_module: nil,
        allow: %{provider_a: ["*"], provider_b: ["*"]},
        deny: %{openai: ["*"], anthropic: ["*"]},
        prefer: []
      }

      {:ok, _} = load_with_test_data(config)

      {:ok, {provider, model_id}} = LLMDB.select(require: [chat: true, tools: true])

      assert provider in [:provider_a, :provider_b]
      assert is_binary(model_id)
    end

    test "select/1 respects prefer order" do
      config = %{
        overrides: %{
          providers: [%{id: :provider_a}, %{id: :provider_b}],
          models: [
            %{
              id: "model-a1",
              provider: :provider_a,
              capabilities: %{chat: true, tools: %{enabled: true}}
            },
            %{
              id: "model-b1",
              provider: :provider_b,
              capabilities: %{chat: true, tools: %{enabled: true}}
            }
          ],
          exclude: %{}
        },
        overrides_module: nil,
        allow: :all,
        deny: %{},
        prefer: [:provider_b, :provider_a]
      }

      {:ok, _} = load_with_test_data(config)

      {:ok, {provider, model_id}} =
        LLMDB.select(require: [chat: true, tools: true], prefer: [:provider_b, :provider_a])

      assert provider == :provider_b
      assert model_id == "model-b1"
    end

    test "select/1 with scope restricts to single provider" do
      config = %{
        overrides: %{
          providers: [%{id: :provider_a}, %{id: :provider_b}],
          models: [
            %{
              id: "model-a1",
              provider: :provider_a,
              capabilities: %{chat: true}
            },
            %{
              id: "model-b1",
              provider: :provider_b,
              capabilities: %{chat: true}
            }
          ],
          exclude: %{}
        },
        overrides_module: nil,
        allow: :all,
        deny: %{},
        prefer: []
      }

      {:ok, _} = load_with_test_data(config)

      {:ok, {provider, model_id}} = LLMDB.select(require: [chat: true], scope: :provider_a)

      assert provider == :provider_a
      assert model_id == "model-a1"
    end

    test "select/1 respects forbid filter" do
      config = %{
        overrides: %{
          providers: [%{id: :provider_a}],
          models: [
            %{
              id: "model-a1",
              provider: :provider_a,
              capabilities: %{chat: true, embeddings: true}
            },
            %{
              id: "model-a2",
              provider: :provider_a,
              capabilities: %{chat: true, embeddings: false}
            }
          ],
          exclude: %{}
        },
        overrides_module: nil,
        allow: %{provider_a: ["*"]},
        deny: %{openai: ["*"], anthropic: ["*"]},
        prefer: []
      }

      {:ok, _} = load_with_test_data(config)

      {:ok, {provider, model_id}} =
        LLMDB.select(require: [chat: true], forbid: [embeddings: true])

      assert provider == :provider_a
      assert model_id == "model-a2"
    end

    test "select/1 returns :no_match when no models match" do
      config = %{
        overrides: %{
          providers: [%{id: :provider_a}],
          models: [
            %{
              id: "model-a1",
              provider: :provider_a,
              capabilities: %{chat: true, tools: %{enabled: false}}
            }
          ],
          exclude: %{}
        },
        overrides_module: nil,
        allow: %{provider_a: ["*"]},
        deny: %{openai: ["*"], anthropic: ["*"]},
        prefer: []
      }

      {:ok, _} = load_with_test_data(config)

      assert {:error, :no_match} = LLMDB.select(require: [tools: true])
    end

    test "select/1 returns :no_match when not loaded" do
      Store.clear!()
      assert {:error, :no_match} = LLMDB.select(require: [chat: true])
    end
  end

  describe "spec parsing" do
    setup do
      {:ok, _} = load_with_test_data(%{overrides: minimal_test_data()})
      :ok
    end

    test "model/1 parses provider:model format" do
      providers = LLMDB.providers()

      if providers != [] do
        provider_id = hd(providers).id
        models = LLMDB.models(provider_id)

        if models != [] do
          model_data = hd(models)
          spec = "#{provider_id}:#{model_data.id}"

          assert {:ok, fetched} = LLMDB.model(spec)
          assert is_struct(fetched, LLMDB.Model)
          assert fetched.id == model_data.id
          assert fetched.provider == provider_id
        end
      end
    end

    test "model/1 returns error for invalid format" do
      assert {:error, :invalid_format} = LLMDB.model("no-colon")
    end

    test "model/1 returns error for unknown provider" do
      assert {:error, :unknown_provider} = LLMDB.model("nonexistent:model")
    end

    test "model/1 prefers a regional Bedrock entry over the base model" do
      Store.clear!()

      {:ok, _} =
        load_with_test_data(%{
          overrides: %{
            providers: [%{id: :amazon_bedrock, name: "Amazon Bedrock"}],
            models: [
              %{
                id: "anthropic.claude-sonnet-4-5-20250929-v1:0",
                provider: :amazon_bedrock,
                capabilities: %{chat: true},
                cost: %{input: 3, output: 15}
              },
              %{
                id: "eu.anthropic.claude-sonnet-4-5-20250929-v1:0",
                provider: :amazon_bedrock,
                capabilities: %{chat: true},
                cost: %{input: 3.3, output: 16.5}
              }
            ]
          }
        })

      assert {:ok, model} =
               LLMDB.model("amazon_bedrock:eu.anthropic.claude-sonnet-4-5-20250929-v1:0")

      assert model.id == "eu.anthropic.claude-sonnet-4-5-20250929-v1:0"
      assert model.cost.input == 3.3

      assert {:ok, model} =
               LLMDB.model("amazon_bedrock:us.anthropic.claude-sonnet-4-5-20250929-v1:0")

      assert model.id == "anthropic.claude-sonnet-4-5-20250929-v1:0"
      assert model.cost.input == 3
    end

    test "model/1 strips Bedrock inference profile prefixes without a regional entry" do
      Store.clear!()

      {:ok, _} =
        load_with_test_data(%{
          overrides: %{
            providers: [%{id: :amazon_bedrock, name: "Amazon Bedrock"}],
            models: [
              %{
                id: "anthropic.claude-sonnet-4-5-20250929-v1:0",
                provider: :amazon_bedrock,
                capabilities: %{chat: true}
              }
            ]
          }
        })

      # Without prefix
      assert {:ok, model} =
               LLMDB.model("amazon_bedrock:anthropic.claude-sonnet-4-5-20250929-v1:0")

      assert model.id == "anthropic.claude-sonnet-4-5-20250929-v1:0"

      # With au. prefix
      assert {:ok, model} =
               LLMDB.model("amazon_bedrock:au.anthropic.claude-sonnet-4-5-20250929-v1:0")

      assert model.id == "anthropic.claude-sonnet-4-5-20250929-v1:0"

      # With us. prefix
      assert {:ok, model} =
               LLMDB.model("amazon_bedrock:us.anthropic.claude-sonnet-4-5-20250929-v1:0")

      assert model.id == "anthropic.claude-sonnet-4-5-20250929-v1:0"

      # With eu. prefix
      assert {:ok, model} =
               LLMDB.model("amazon_bedrock:eu.anthropic.claude-sonnet-4-5-20250929-v1:0")

      assert model.id == "anthropic.claude-sonnet-4-5-20250929-v1:0"
    end

    test "model/2 resolves model by provider and id" do
      providers = LLMDB.providers()

      if providers != [] do
        provider_id = hd(providers).id
        models = LLMDB.models(provider_id)

        if models != [] do
          model_data = hd(models)

          assert {:ok, resolved_model} = LLMDB.model(provider_id, model_data.id)
          assert resolved_model.id == model_data.id
          assert resolved_model.provider == provider_id
        end
      end
    end

    test "model/2 resolves alias to canonical model" do
      providers = LLMDB.providers()

      if providers != [] do
        provider_id = hd(providers).id
        models = LLMDB.models(provider_id)

        model_with_alias = Enum.find(models, fn m -> m.aliases != [] end)

        if model_with_alias do
          alias_name = hd(model_with_alias.aliases)

          assert {:ok, resolved_model} = LLMDB.model(provider_id, alias_name)
          assert resolved_model.id == model_with_alias.id
        end
      end
    end

    test "model/2 returns error for unknown model" do
      assert {:error, :not_found} = LLMDB.model(:openai, "nonexistent")
    end

    test "model/1 with string spec resolves model" do
      providers = LLMDB.providers()

      if providers != [] do
        provider_id = hd(providers).id
        models = LLMDB.models(provider_id)

        if models != [] do
          model_data = hd(models)
          spec = "#{provider_id}:#{model_data.id}"

          assert {:ok, resolved_model} = LLMDB.model(spec)
          assert resolved_model.id == model_data.id
          assert resolved_model.provider == provider_id
        end
      end
    end
  end

  describe "capability predicates" do
    test "matches chat capability" do
      config = %{
        overrides: %{
          providers: [%{id: :test_provider}],
          models: [
            %{id: "chat-model", provider: :test_provider, capabilities: %{chat: true}},
            %{id: "no-chat-model", provider: :test_provider, capabilities: %{chat: false}}
          ],
          exclude: %{}
        },
        overrides_module: nil,
        allow: :all,
        deny: %{},
        prefer: []
      }

      {:ok, _} = load_with_test_data(config)

      models =
        LLMDB.models(:test_provider)
        |> Enum.filter(fn m -> m.capabilities.chat == true end)

      assert length(models) == 1
      assert hd(models).id == "chat-model"
    end

    test "matches nested tool capabilities" do
      config = %{
        overrides: %{
          providers: [%{id: :test_provider}],
          models: [
            %{
              id: "tools-model",
              provider: :test_provider,
              capabilities: %{tools: %{enabled: true, streaming: true}}
            },
            %{
              id: "no-tools-model",
              provider: :test_provider,
              capabilities: %{tools: %{enabled: false}}
            }
          ],
          exclude: %{}
        },
        overrides_module: nil,
        allow: :all,
        deny: %{},
        prefer: []
      }

      {:ok, _} = load_with_test_data(config)

      models =
        LLMDB.models(:test_provider)
        |> Enum.filter(fn m -> get_in(m.capabilities, [:tools, :enabled]) == true end)

      assert length(models) == 1
      assert hd(models).id == "tools-model"

      models =
        LLMDB.models(:test_provider)
        |> Enum.filter(fn m ->
          get_in(m.capabilities, [:tools, :enabled]) == true and
            get_in(m.capabilities, [:tools, :streaming]) == true
        end)

      assert length(models) == 1
      assert hd(models).id == "tools-model"
    end

    test "matches nested json capabilities" do
      config = %{
        overrides: %{
          providers: [%{id: :test_provider}],
          models: [
            %{
              id: "json-model",
              provider: :test_provider,
              capabilities: %{json: %{native: true, schema: true}}
            },
            %{
              id: "no-json-model",
              provider: :test_provider,
              capabilities: %{json: %{native: false}}
            }
          ],
          exclude: %{}
        },
        overrides_module: nil,
        allow: :all,
        deny: %{},
        prefer: []
      }

      {:ok, _} = load_with_test_data(config)

      models =
        LLMDB.models(:test_provider)
        |> Enum.filter(fn m -> get_in(m.capabilities, [:json, :native]) == true end)

      assert length(models) == 1
      assert hd(models).id == "json-model"

      models =
        LLMDB.models(:test_provider)
        |> Enum.filter(fn m ->
          get_in(m.capabilities, [:json, :native]) == true and
            get_in(m.capabilities, [:json, :schema]) == true
        end)

      assert length(models) == 1
      assert hd(models).id == "json-model"
    end

    test "matches nested streaming capabilities" do
      config = %{
        overrides: %{
          providers: [%{id: :test_provider}],
          models: [
            %{
              id: "streaming-model",
              provider: :test_provider,
              capabilities: %{streaming: %{text: true, tool_calls: true}}
            },
            %{
              id: "no-streaming-model",
              provider: :test_provider,
              capabilities: %{streaming: %{text: false, tool_calls: false}}
            }
          ],
          exclude: %{}
        },
        overrides_module: nil,
        allow: :all,
        deny: %{},
        prefer: []
      }

      {:ok, _} = load_with_test_data(config)

      models =
        LLMDB.models(:test_provider)
        |> Enum.filter(fn m -> get_in(m.capabilities, [:streaming, :tool_calls]) == true end)

      assert length(models) == 1
      assert hd(models).id == "streaming-model"
    end
  end

  describe "integration tests" do
    test "full pipeline: load, list, get, select" do
      config = %{
        overrides: %{
          providers: [
            %{id: :provider_a, name: "Provider A"},
            %{id: :provider_b, name: "Provider B"}
          ],
          models: [
            %{
              id: "model-a1",
              provider: :provider_a,
              capabilities: %{
                chat: true,
                tools: %{enabled: true, streaming: false},
                json: %{native: true}
              },
              aliases: ["model-a1-alias"]
            },
            %{
              id: "model-a2",
              provider: :provider_a,
              capabilities: %{chat: true, embeddings: true}
            },
            %{
              id: "model-b1",
              provider: :provider_b,
              capabilities: %{
                chat: true,
                tools: %{enabled: true, streaming: true},
                json: %{native: true}
              }
            }
          ],
          exclude: %{}
        },
        overrides_module: nil,
        allow: :all,
        deny: %{},
        prefer: [:provider_a, :provider_b]
      }

      {:ok, snapshot} = load_with_test_data(config)

      assert is_map(snapshot)

      providers = LLMDB.providers()
      provider_ids = Enum.map(providers, & &1.id)
      assert :provider_a in provider_ids
      assert :provider_b in provider_ids

      {:ok, provider_a} = LLMDB.provider(:provider_a)
      assert provider_a.name == "Provider A"

      models_a = LLMDB.models(:provider_a)
      assert length(models_a) == 2

      {:ok, model} = LLMDB.model(:provider_a, "model-a1")
      assert model.id == "model-a1"

      {:ok, model_via_alias} = LLMDB.model(:provider_a, "model-a1-alias")
      assert model_via_alias.id == "model-a1"

      caps = LLMDB.capabilities({:provider_a, "model-a1"})
      assert caps.chat == true
      assert caps.tools.enabled == true

      assert LLMDB.allowed?({:provider_a, "model-a1"}) == true

      {:ok, {provider, model_id}} =
        LLMDB.select(
          require: [chat: true, tools: true],
          prefer: [:provider_a, :provider_b]
        )

      assert provider == :provider_a
      assert model_id == "model-a1"

      {:ok, resolved_model} = LLMDB.model("provider_a:model-a1")
      assert resolved_model.provider == :provider_a
      assert resolved_model.id == "model-a1"

      # reload is just calling load again
      {:ok, _} = LLMDB.load()
      assert LLMDB.epoch() > 0
    end

    test "filters work with deny patterns" do
      config = %{
        overrides: %{
          providers: [%{id: :test_provider}],
          models: [
            %{id: "allowed-model", provider: :test_provider, capabilities: %{chat: true}},
            %{id: "denied-model", provider: :test_provider, capabilities: %{chat: true}}
          ],
          exclude: %{}
        },
        overrides_module: nil,
        allow: %{test_provider: ["*"]},
        deny: %{test_provider: ["denied-model"], openai: ["*"], anthropic: ["*"]},
        prefer: []
      }

      {:ok, _} = load_with_test_data(config)

      assert LLMDB.allowed?({:test_provider, "allowed-model"}) == true
      assert LLMDB.allowed?({:test_provider, "denied-model"}) == false

      {:ok, {provider, model_id}} = LLMDB.select(require: [chat: true])
      assert provider == :test_provider
      assert model_id == "allowed-model"
    end
  end

  describe "error cases" do
    test "handles missing capabilities gracefully" do
      config = %{
        overrides: %{
          providers: [%{id: :test_provider}],
          models: [
            %{id: "minimal-model", provider: :test_provider}
          ],
          exclude: %{}
        },
        overrides_module: nil,
        allow: :all,
        deny: %{},
        prefer: []
      }

      {:ok, _} = load_with_test_data(config)

      models =
        LLMDB.models(:test_provider)
        |> Enum.filter(fn m -> get_in(m.capabilities, [:chat]) == true end)

      assert models == []
    end

    test "handles invalid spec format" do
      {:ok, _} = load_with_test_data(%{overrides: minimal_test_data()})

      assert {:error, :invalid_format} = LLMDB.model("invalid")
    end

    test "handles snapshot not loaded" do
      Store.clear!()

      assert LLMDB.providers() == []
      assert LLMDB.provider(:openai) == {:error, :not_found}
      assert LLMDB.models(:openai) == []
      assert LLMDB.model(:openai, "gpt-4") == {:error, :not_found}
      assert LLMDB.capabilities({:openai, "gpt-4"}) == nil
      assert LLMDB.allowed?({:openai, "gpt-4"}) == false
      assert {:error, :no_match} = LLMDB.select(require: [chat: true])
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

  describe "packaged catalog regressions" do
    setup do
      {:ok, _snapshot} = LLMDB.load()
      :ok
    end

    test "model/1 resolves ElevenLabs TTS models by string spec" do
      assert {:ok, model} = LLMDB.model("elevenlabs:eleven_multilingual_v2")

      assert model.provider == :elevenlabs
      assert model.id == "eleven_multilingual_v2"
      assert model.modalities.input == [:text]
      assert model.modalities.output == [:audio]
      assert model.capabilities.chat == false
      assert model.capabilities.embeddings == false
      assert model.extra["api"] == "tts"
    end
  end
end
