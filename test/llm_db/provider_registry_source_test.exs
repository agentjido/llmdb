defmodule LLMDB.ProviderRegistrySourceTest do
  use ExUnit.Case, async: true

  alias LLMDB.Generated.ProviderRegistry.Source

  test "loads bounded provider atoms only from a trusted snapshot file" do
    path = write_json!(%{"providers" => %{"registry_test_provider" => %{}}})
    on_exit(fn -> File.rm!(path) end)

    assert [{"registry_test_provider", :registry_test_provider}] = Source.load!(path)
  end

  test "fails closed when the trusted snapshot is absent or malformed" do
    missing = Path.join(System.tmp_dir!(), "missing-#{System.unique_integer([:positive])}.json")

    assert_raise File.Error, fn -> Source.load!(missing) end

    malformed = write_json!(%{"not_providers" => %{}})
    on_exit(fn -> File.rm!(malformed) end)

    assert_raise KeyError, fn -> Source.load!(malformed) end
  end

  test "rejects unsafe IDs before creating provider atoms" do
    unsafe_id = "unsafe provider #{System.unique_integer([:positive])}"
    path = write_json!(%{"providers" => %{unsafe_id => %{}}})
    on_exit(fn -> File.rm!(path) end)

    assert_raise ArgumentError, ~r/invalid provider ID/, fn -> Source.load!(path) end
    assert_raise ArgumentError, fn -> String.to_existing_atom(unsafe_id) end
  end

  test "caps the number of provider atoms compiled from the trusted artifact" do
    providers = Map.new(0..1_024, &{"provider_#{&1}", %{}})
    path = write_json!(%{"providers" => providers})
    on_exit(fn -> File.rm!(path) end)

    assert_raise ArgumentError, ~r/1024-provider limit/, fn -> Source.load!(path) end
  end

  defp write_json!(document) do
    path =
      Path.join(
        System.tmp_dir!(),
        "llmdb-registry-source-#{System.unique_integer([:positive])}.json"
      )

    File.write!(path, Jason.encode!(document))
    path
  end
end
