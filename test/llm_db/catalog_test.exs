defmodule LLMDB.CatalogTest do
  use ExUnit.Case, async: false

  alias LLMDB.{Catalog, Model, Provider, Spec, Store}

  setup do
    Catalog.clear!()
    on_exit(&Catalog.clear!/0)
    :ok
  end

  test "builds the canonical indexes and retains snapshot identity" do
    catalog = catalog_fixture()

    assert catalog.providers_by_id.google_vertex.name == "Google Vertex"

    assert catalog.models_by_key[{:google_vertex_anthropic, "claude-model"}].name ==
             "Claude Model"

    assert catalog.aliases_by_key[{:google_vertex_anthropic, "claude-alias"}] ==
             "claude-model"

    assert catalog.meta.source_snapshot_id == "snapshot-123"
    assert catalog.meta.digest == "semantic-digest"
    assert catalog.meta.source_generated_at == "2026-07-16T00:00:00Z"
  end

  test "provider and model aliases share one map-based resolution path" do
    catalog = catalog_fixture()

    # Resolution continues from immutable indexes even if the presentation list
    # is absent, proving direct lookup does not scan providers.
    indexed_only = Map.put(catalog, :providers, [])

    assert {:ok, {:google_vertex, "claude-model", model}} =
             Catalog.resolve_model(indexed_only, :google_vertex, "claude-alias")

    assert model.id == "claude-model"
    assert model.provider == :google_vertex
  end

  test "Store and Spec compatibility facades resolve through Catalog" do
    catalog = catalog_fixture()
    Catalog.put!(catalog, source: :test)

    assert {:ok, store_model} = Store.model(:google_vertex, "claude-alias")

    assert {:ok, {:google_vertex, "claude-model", spec_model}} =
             Spec.resolve({:google_vertex, "claude-alias"})

    assert store_model == spec_model
    assert Catalog.last_opts() == [source: :test]
  end

  test "runtime views rebuild every model resolution index" do
    catalog = catalog_fixture()
    filtered = Catalog.with_runtime_view(catalog, [], %{allow: %{}, deny: %{}})

    assert {:error, :not_found} =
             Catalog.resolve_model(filtered, :google_vertex, "claude-alias")

    assert {:error, :not_found} = Catalog.resolve_bare(filtered, "claude-alias")
  end

  test "legacy string alias_of values resolve without creating provider atoms" do
    catalog =
      catalog_fixture()
      |> update_in([:providers], fn providers ->
        Enum.map(providers, fn provider ->
          if provider.id == :google_vertex_anthropic do
            provider |> Map.from_struct() |> Map.put(:alias_of, "google_vertex")
          else
            provider
          end
        end)
      end)
      |> Map.delete(:__llm_db_provider_lookup_ids__)

    assert {:ok, model} = Catalog.model(catalog, :google_vertex, "claude-alias")
    assert model.provider == :google_vertex
  end

  test "bare aliases retain precedence over colliding canonical IDs" do
    provider = Provider.new!(%{id: :openrouter, name: "OpenRouter"})

    alias_target =
      Model.new!(%{
        id: "canonical-target",
        provider: :openrouter,
        aliases: ["colliding-id"]
      })

    colliding_model = Model.new!(%{id: "colliding-id", provider: :openrouter})
    catalog = build_catalog([provider], [alias_target, colliding_model])

    assert {:ok, {:openrouter, "canonical-target", model}} =
             Catalog.resolve_bare(catalog, "colliding-id")

    assert model.id == "canonical-target"
  end

  test "Bedrock-prefixed IDs resolve to their regional entry when the catalog has one" do
    provider = Provider.new!(%{id: :amazon_bedrock, name: "Amazon Bedrock"})

    base =
      Model.new!(%{
        id: "anthropic.model",
        provider: :amazon_bedrock,
        aliases: ["eu.anthropic.model"],
        cost: %{input: 5, output: 25}
      })

    regional =
      Model.new!(%{
        id: "eu.anthropic.model",
        provider: :amazon_bedrock,
        cost: %{input: 5.5, output: 27.5}
      })

    catalog = build_catalog([provider], [base, regional])

    assert {:ok, {:amazon_bedrock, "eu.anthropic.model", model}} =
             Catalog.resolve_model(catalog, :amazon_bedrock, "eu.anthropic.model")

    assert model.id == "eu.anthropic.model"
    assert model.cost.input == 5.5

    assert {:ok, {:amazon_bedrock, "eu.anthropic.model", bare}} =
             Catalog.resolve_bare(catalog, "eu.anthropic.model")

    assert bare.id == "eu.anthropic.model"
  end

  test "Bedrock-prefixed IDs fall back to the base model when no regional entry exists" do
    provider = Provider.new!(%{id: :amazon_bedrock, name: "Amazon Bedrock"})

    base =
      Model.new!(%{
        id: "anthropic.model",
        provider: :amazon_bedrock,
        cost: %{input: 5, output: 25}
      })

    catalog = build_catalog([provider], [base])

    assert {:ok, {:amazon_bedrock, "us.anthropic.model", model}} =
             Catalog.resolve_model(catalog, :amazon_bedrock, "us.anthropic.model")

    assert model.id == "anthropic.model"

    assert {:ok, {:amazon_bedrock, "us.anthropic.model", bare}} =
             Catalog.resolve_bare(catalog, "us.anthropic.model")

    assert bare.id == "anthropic.model"
  end

  test "Bedrock regional aliases retain their prefix without false ambiguity" do
    provider = Provider.new!(%{id: :amazon_bedrock, name: "Amazon Bedrock"})

    base =
      Model.new!(%{
        id: "anthropic.model",
        provider: :amazon_bedrock,
        aliases: ["eu.anthropic.model", "anthropic.alias"],
        cost: %{input: 5, output: 25}
      })

    catalog = build_catalog([provider], [base])
    Catalog.put!(catalog, source: :test)

    for lookup_id <- ["eu.anthropic.model", "eu.anthropic.alias", "us.anthropic.alias"] do
      {_, prefix} = Catalog.strip_prefix(:amazon_bedrock, lookup_id)
      expected_id = prefix <> "anthropic.model"

      assert {:ok, {:amazon_bedrock, ^expected_id, ^base}} =
               Catalog.resolve_model(catalog, :amazon_bedrock, lookup_id)

      assert {:ok, {:amazon_bedrock, ^expected_id, ^base}} =
               Catalog.resolve_bare(catalog, lookup_id)

      for spec <- [
            "amazon_bedrock:" <> lookup_id,
            lookup_id <> "@amazon_bedrock",
            {:amazon_bedrock, lookup_id},
            lookup_id
          ] do
        assert {:ok, {:amazon_bedrock, ^expected_id, ^base}} = Spec.resolve(spec)
      end
    end
  end

  test "Bedrock regional aliases resolve without a matching stripped ID" do
    provider = Provider.new!(%{id: :amazon_bedrock, name: "Amazon Bedrock"})

    base =
      Model.new!(%{
        id: "anthropic.model",
        provider: :amazon_bedrock,
        aliases: ["eu.profile-alias"]
      })

    catalog = build_catalog([provider], [base])

    assert {:ok, {:amazon_bedrock, "eu.anthropic.model", ^base}} =
             Catalog.resolve_model(catalog, :amazon_bedrock, "eu.profile-alias")

    assert {:ok, {:amazon_bedrock, "eu.anthropic.model", ^base}} =
             Catalog.resolve_bare(catalog, "eu.profile-alias")
  end

  test "Bedrock aliases to regional entries do not add a second prefix" do
    provider = Provider.new!(%{id: :amazon_bedrock, name: "Amazon Bedrock"})
    base = Model.new!(%{id: "anthropic.model", provider: :amazon_bedrock})

    regional =
      Model.new!(%{
        id: "eu.anthropic.regional-model",
        provider: :amazon_bedrock,
        aliases: ["eu.anthropic.model"]
      })

    catalog = build_catalog([provider], [base, regional])

    assert {:ok, {:amazon_bedrock, "eu.anthropic.regional-model", ^regional}} =
             Catalog.resolve_model(catalog, :amazon_bedrock, "eu.anthropic.model")

    assert {:ok, {:amazon_bedrock, "eu.anthropic.regional-model", ^regional}} =
             Catalog.resolve_bare(catalog, "eu.anthropic.model")
  end

  test "Bedrock regional matches retain ambiguity with another provider" do
    providers = [
      Provider.new!(%{id: :amazon_bedrock, name: "Amazon Bedrock"}),
      Provider.new!(%{id: :openrouter, name: "OpenRouter"})
    ]

    models = [
      Model.new!(%{
        id: "anthropic.model",
        provider: :amazon_bedrock,
        aliases: ["eu.anthropic.model"]
      }),
      Model.new!(%{id: "eu.anthropic.model", provider: :openrouter})
    ]

    catalog = build_catalog(providers, models)
    assert {:error, :ambiguous} = Catalog.resolve_bare(catalog, "eu.anthropic.model")
  end

  test "provider metadata enables prefix resolution with the longest matching prefix" do
    provider =
      Provider.new!(%{
        id: :openrouter,
        extra: %{"model_id_prefixes" => ["tenant.", "", nil, 12, "tenant.eu.", "tenant."]}
      })

    base =
      Model.new!(%{
        id: "model",
        provider: :openrouter,
        aliases: ["tenant.eu.model", "tenant.eu.base-alias", "short"],
        cost: %{input: 2, output: 10}
      })

    scoped =
      Model.new!(%{
        id: "tenant.eu.model",
        provider: :openrouter,
        aliases: ["tenant.eu.scoped-alias"],
        cost: %{input: 3, output: 15}
      })

    catalog = build_catalog([provider], [base, scoped])
    Catalog.put!(catalog, source: :test)

    assert Spec.strip_prefix(:openrouter, "tenant.eu.model") == {"model", "tenant.eu."}

    for {lookup_id, expected_id, expected_model} <- [
          {"tenant.eu.model", "tenant.eu.model", scoped},
          {"tenant.eu.scoped-alias", "tenant.eu.model", scoped},
          {"tenant.eu.base-alias", "tenant.eu.model", scoped},
          {"tenant.eu.short", "tenant.eu.model", scoped},
          {"tenant.model", "tenant.model", base}
        ] do
      assert {:ok, {:openrouter, ^expected_id, ^expected_model}} =
               Catalog.resolve_model(catalog, :openrouter, lookup_id)

      assert {:ok, {:openrouter, ^expected_id, ^expected_model}} =
               Catalog.resolve_bare(catalog, lookup_id)

      for spec <- [
            "openrouter:" <> lookup_id,
            lookup_id <> "@openrouter",
            {:openrouter, lookup_id},
            lookup_id
          ] do
        assert {:ok, {:openrouter, ^expected_id, ^expected_model}} = Spec.resolve(spec)
      end

      assert {:ok, ^expected_model} = LLMDB.model("openrouter:" <> lookup_id)
    end

    indexed_only = Map.put(catalog, :providers, [])

    assert {:ok, {:openrouter, "tenant.model", ^base}} =
             Catalog.resolve_model(indexed_only, :openrouter, "tenant.model")

    legacy =
      catalog
      |> Map.delete(:__llm_db_model_id_prefixes__)
      |> Map.put(:providers, [])

    assert {:ok, {:openrouter, "tenant.model", ^base}} =
             Catalog.resolve_model(legacy, :openrouter, "tenant.model")

    filtered = Catalog.with_runtime_view(catalog, [base], %{allow: :all, deny: %{}})

    assert {:ok, {:openrouter, "tenant.eu.model", ^base}} =
             Catalog.resolve_model(filtered, :openrouter, "tenant.eu.short")

    assert {:ok, {:openrouter, "tenant.eu.model", ^base}} =
             Catalog.resolve_bare(filtered, "tenant.eu.short")
  end

  test "prefix rules apply only to providers that declare them" do
    providers = [
      Provider.new!(%{id: :openrouter, extra: %{model_id_prefixes: ["tenant."]}}),
      Provider.new!(%{id: :openai})
    ]

    models = [
      Model.new!(%{id: "model", provider: :openrouter}),
      Model.new!(%{id: "model", provider: :openai})
    ]

    catalog = build_catalog(providers, models)

    assert {:ok, {:openrouter, "tenant.model", _model}} =
             Catalog.resolve_bare(catalog, "tenant.model")

    assert {:error, :not_found} = Catalog.resolve_model(catalog, :openai, "tenant.model")

    both_configured = [
      hd(providers),
      Provider.new!(%{id: :openai, extra: %{model_id_prefixes: ["tenant."]}})
    ]

    assert {:error, :ambiguous} =
             both_configured
             |> build_catalog(models)
             |> Catalog.resolve_bare("tenant.model")
  end

  test "prefix lookup through provider aliases does not create false ambiguity" do
    primary =
      Provider.new!(%{id: :google_vertex, extra: %{model_id_prefixes: ["tenant."]}})

    base =
      Model.new!(%{
        id: "model",
        provider: :google_vertex_anthropic,
        aliases: ["tenant.model", "tenant.base-alias", "short"],
        cost: %{input: 2, output: 10}
      })

    scoped =
      Model.new!(%{
        id: "tenant.model",
        provider: :google_vertex_anthropic,
        cost: %{input: 3, output: 15}
      })

    normalized = %{scoped | provider: :google_vertex}

    for extra <- [nil, %{model_id_prefixes: ["tenant."]}] do
      alias_provider = Provider.new!(%{id: :google_vertex_anthropic, extra: extra})
      catalog = build_catalog([primary, alias_provider], [base, scoped])

      for lookup_id <- ["tenant.model", "tenant.base-alias", "tenant.short"] do
        assert {:ok, {:google_vertex, "tenant.model", ^normalized}} =
                 Catalog.resolve_model(catalog, :google_vertex, lookup_id)

        assert {:ok, {:google_vertex_anthropic, "tenant.model", ^scoped}} =
                 Catalog.resolve_bare(catalog, lookup_id)
      end
    end
  end

  test "different prefix routes through provider aliases remain ambiguous" do
    providers = [
      Provider.new!(%{id: :google_vertex, extra: %{model_id_prefixes: ["tenant."]}}),
      Provider.new!(%{
        id: :google_vertex_anthropic,
        extra: %{model_id_prefixes: ["tenant.eu."]}
      })
    ]

    model =
      Model.new!(%{
        id: "model",
        provider: :google_vertex_anthropic,
        aliases: ["tenant.eu.alias"]
      })

    for ordering <- [providers, Enum.reverse(providers)] do
      assert {:error, :ambiguous} =
               ordering
               |> build_catalog([model])
               |> Catalog.resolve_bare("tenant.eu.alias")
    end
  end

  test "provider prefix metadata can disable compatibility defaults" do
    provider =
      Provider.new!(%{id: :amazon_bedrock, extra: %{model_id_prefixes: []}})

    base = Model.new!(%{id: "model", provider: :amazon_bedrock})
    catalog = build_catalog([provider], [base])

    assert {:error, :not_found} = Catalog.resolve_model(catalog, :amazon_bedrock, "eu.model")
    assert {:error, :not_found} = Catalog.resolve_bare(catalog, "eu.model")
  end

  defp catalog_fixture do
    providers = [
      Provider.new!(%{id: :google_vertex, name: "Google Vertex"}),
      Provider.new!(%{id: :google_vertex_anthropic, name: "Vertex Anthropic"})
    ]

    model =
      Model.new!(%{
        id: "claude-model",
        provider: :google_vertex_anthropic,
        name: "Claude Model",
        aliases: ["claude-alias"]
      })

    build_catalog(providers, [model])
  end

  defp build_catalog(providers, models) do
    Catalog.build(providers, models, models,
      filters: %{allow: :all, deny: %{}},
      prefer: [:google_vertex],
      source_generated_at: "2026-07-16T00:00:00Z",
      source_snapshot_id: "snapshot-123",
      loaded_at: "2026-07-16T00:01:00Z",
      digest: "semantic-digest"
    )
  end
end
