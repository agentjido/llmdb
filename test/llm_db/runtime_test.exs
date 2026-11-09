defmodule LLMDB.RuntimeTest do
  use ExUnit.Case, async: true

  alias LLMDB.Runtime

  test "custom provider normalization preserves explicit runtime and boolean metadata" do
    metadata = %{base_url: "https://gateway.example/v1", auth: %{type: "bearer", env: []}}

    for catalog_only <- [false, true] do
      runtime =
        Runtime.compile(
          custom: %{
            test: [runtime: metadata, catalog_only: catalog_only, unknown_field: "ignored"]
          }
        )

      assert runtime.custom.providers == [
               %{id: :test, runtime: metadata, catalog_only: catalog_only}
             ]
    end
  end

  test "custom provider normalization leaves absent and nil metadata sparse" do
    for config <- [[], [runtime: nil, catalog_only: nil]] do
      assert Runtime.compile(custom: %{test: config}).custom.providers == [%{id: :test}]
    end
  end

  test "custom providers include pricing_defaults" do
    runtime =
      Runtime.compile(
        custom: %{
          test: [
            pricing_defaults: %{
              currency: "USD",
              components: [
                %{id: "tool.web_search", kind: "tool", unit: "call", per: 1000, rate: 10.0}
              ]
            }
          ]
        }
      )

    [provider] = runtime.custom.providers
    assert provider.pricing_defaults.currency == "USD"
    assert [%{id: "tool.web_search"}] = provider.pricing_defaults.components
  end
end
