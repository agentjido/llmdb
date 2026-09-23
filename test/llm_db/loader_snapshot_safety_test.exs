defmodule LLMDB.LoaderSnapshotSafetyTest do
  use ExUnit.Case, async: true

  alias LLMDB.{Loader, Snapshot}

  test "unknown nested keys remain strings and do not create atoms" do
    unknown_key = unique_identifier("unknown_nested_key")
    assert_not_existing_atom(unknown_key)

    path =
      write_snapshot!(%{
        "test_provider_alpha" => %{
          "id" => "test_provider_alpha",
          "name" => "Test Provider",
          "extra" => %{unknown_key => %{"id" => "opaque"}},
          "models" => %{
            "safe-model" => %{
              "id" => "safe-model",
              "provider" => "test_provider_alpha",
              "extra" => %{unknown_key => %{"capabilities" => "opaque"}}
            }
          }
        }
      })

    on_exit(fn -> File.rm(path) end)

    assert {:ok, snapshot} = Loader.load(snapshot_source: {:file, path})
    provider = snapshot.providers_by_id.test_provider_alpha
    model = snapshot.models_by_key[{:test_provider_alpha, "safe-model"}]

    assert provider.extra == %{unknown_key => %{"id" => "opaque"}}
    assert model.extra == %{unknown_key => %{"capabilities" => "opaque"}}
    assert_not_existing_atom(unknown_key)
  end

  test "unknown provider IDs are rejected without creating atoms" do
    provider_id = unique_identifier("unknown_provider")
    assert_not_existing_atom(provider_id)

    path =
      write_snapshot!(%{
        provider_id => %{
          "id" => provider_id,
          "name" => "Unknown Provider",
          "models" => %{}
        }
      })

    on_exit(fn -> File.rm(path) end)

    assert {:error, {:invalid_snapshot_item, :provider, {:unknown_provider_id, ^provider_id}}} =
             Loader.load(snapshot_source: {:file, path})

    assert_not_existing_atom(provider_id)
  end

  test "model cost exclusions survive snapshot loading and block legacy synthesis" do
    path =
      write_snapshot!(%{
        "test_provider_alpha" => %{
          "id" => "test_provider_alpha",
          "models" => %{
            "priced-model" => %{
              "id" => "priced-model",
              "provider" => "test_provider_alpha",
              "cost" => %{"output" => 2, "reasoning" => 2},
              "pricing" => %{
                "excluded_cost_components" => ["token.reasoning"],
                "components" => []
              }
            }
          }
        }
      })

    on_exit(fn -> File.rm(path) end)

    assert {:ok, snapshot} = Loader.load(snapshot_source: {:file, path})
    model = snapshot.models_by_key[{:test_provider_alpha, "priced-model"}]
    assert model.pricing.excluded_cost_components == ["token.reasoning"]
    assert Enum.map(model.pricing.components, & &1.id) == ["token.output"]
  end

  test "unknown modalities are rejected without creating atoms" do
    modality = unique_identifier("unknown_modality")
    assert_not_existing_atom(modality)

    path =
      write_snapshot!(%{
        "test_provider_alpha" => %{
          "id" => "test_provider_alpha",
          "name" => "Test Provider",
          "models" => %{
            "unsafe-model" => %{
              "id" => "unsafe-model",
              "provider" => "test_provider_alpha",
              "modalities" => %{"input" => [modality], "output" => ["text"]}
            }
          }
        }
      })

    on_exit(fn -> File.rm(path) end)

    assert {:error, {:invalid_snapshot_item, :model, {:unknown_modality, ^modality}}} =
             Loader.load(snapshot_source: {:file, path})

    assert_not_existing_atom(modality)
  end

  defp write_snapshot!(providers) do
    path =
      Path.join(
        System.tmp_dir!(),
        "llm-db-safe-snapshot-#{System.unique_integer([:positive])}.json"
      )

    document = %{
      "schema_version" => Snapshot.schema_version(),
      "version" => 2,
      "generated_at" => "2026-07-16T00:00:00Z",
      "providers" => providers
    }

    document = Map.put(document, "snapshot_id", Snapshot.snapshot_id(document))
    Snapshot.write!(path, document)
    path
  end

  defp unique_identifier(prefix) do
    "#{prefix}_#{System.unique_integer([:positive])}"
  end

  defp assert_not_existing_atom(value) do
    assert_raise ArgumentError, fn -> String.to_existing_atom(value) end
  end
end
