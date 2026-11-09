defmodule LLMDB.CustomProviderMetadataTest do
  use ExUnit.Case, async: false

  alias LLMDB.{Engine, Snapshot, Store}
  alias LLMDB.Sources.Config, as: ConfigSource

  @gateway "https://gateway.example/v1"
  @runtime %{base_url: @gateway, auth: %{type: "bearer", env: []}}

  setup do
    original = Store.get()
    Store.clear!()

    path =
      Path.join(System.tmp_dir!(), "custom-provider-#{System.unique_integer([:positive])}.json")

    on_exit(fn ->
      File.rm(path)
      Store.clear!()
      if original, do: Store.put!(original.snapshot, original.opts)
    end)

    {:ok, snapshot} =
      Engine.run(
        sources: [
          {ConfigSource,
           %{
             overrides: %{
               providers: [
                 %{
                   id: :metadata_base,
                   name: "Base provider",
                   catalog_only: true,
                   runtime: %{
                     base_url: "https://base.example/v1",
                     auth: %{type: "bearer", env: ["BASE_API_KEY"]},
                     default_headers: %{"x-base" => "preserved"}
                   }
                 }
               ],
               models: [
                 %{id: "base-model", provider: :metadata_base, capabilities: %{chat: true}}
               ]
             }
           }}
        ]
      )

    Snapshot.write!(path, Snapshot.from_engine_snapshot(snapshot))
    %{path: path}
  end

  test "load retains runtime auth and both explicit catalog_only values", %{path: path} do
    for catalog_only <- [false, true] do
      assert {:ok, _} =
               load_custom(path, %{
                 zaq_router: [
                   runtime: @runtime,
                   catalog_only: catalog_only,
                   models: %{"router-model" => %{capabilities: %{chat: true}}}
                 ]
               })

      assert {:ok, provider} = LLMDB.provider(:zaq_router)
      assert provider.catalog_only == catalog_only
      assert provider.runtime.base_url == @gateway
      assert provider.runtime.auth.type == "bearer"
      assert provider.runtime.auth.env == []
      assert {:ok, model} = LLMDB.model(:zaq_router, "router-model")
      assert model.provider == :zaq_router
      assert model.capabilities.chat == true
    end
  end

  test "load applies normal defaults when provider metadata is absent", %{path: path} do
    assert {:ok, _} =
             load_custom(path, %{
               zaq_router: [models: %{"router-model" => %{capabilities: %{chat: true}}}]
             })

    assert {:ok, provider} = LLMDB.provider(:zaq_router)
    assert provider.runtime == nil
    assert provider.catalog_only == false
  end

  test "existing provider merges explicit false and runtime without losing nested metadata", %{
    path: path
  } do
    assert {:ok, _} =
             load_custom(path, %{
               metadata_base: [runtime: @runtime, catalog_only: false]
             })

    assert {:ok, provider} = LLMDB.provider(:metadata_base)
    assert provider.name == "Base provider"
    assert provider.catalog_only == false
    assert provider.runtime.base_url == @gateway
    assert provider.runtime.auth.type == "bearer"
    assert provider.runtime.auth.env == []
    assert provider.runtime.default_headers == %{"x-base" => "preserved"}
    assert {:ok, _} = LLMDB.model(:metadata_base, "base-model")
  end

  test "existing provider retains metadata omitted by a sparse custom overlay", %{path: path} do
    assert {:ok, _} = load_custom(path, %{metadata_base: [name: "Renamed"]})
    assert {:ok, provider} = LLMDB.provider(:metadata_base)
    assert provider.name == "Renamed"
    assert provider.catalog_only == true
    assert provider.runtime.base_url == "https://base.example/v1"
    assert provider.runtime.auth.env == ["BASE_API_KEY"]
  end

  defp load_custom(path, custom) do
    LLMDB.load(
      snapshot_source: {:file, path},
      allow: :all,
      deny: %{},
      prefer: [],
      custom: custom
    )
  end
end
