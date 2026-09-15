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
