defmodule LLMDB.Schema.PricingTest do
  use ExUnit.Case, async: true

  alias LLMDB.{Model, Provider, Validate}

  @pricing %{
    currency: "USD",
    components: [
      %{
        id: "token.input.long_context",
        kind: "token",
        unit: "token",
        per: 1_000_000,
        rate: 10.0,
        meter: "input_tokens",
        tool: :web_search,
        size_class: "long",
        multiplier: 2.0,
        derives_from: "token.input",
        applies_to: ["token.*"],
        applies_when: %{input_tokens: %{gt: 272_000}},
        excludes_when: %{api: "batch"},
        mode: "standard",
        charge_scope: "full_request",
        source: "provider_docs",
        notes: "Long-context tier"
      }
    ]
  }

  test "model and provider parents parse shared pricing fields identically" do
    model = Model.new!(%{id: "model", provider: :provider, pricing: @pricing})
    provider = Provider.new!(%{id: :provider, pricing_defaults: @pricing})

    assert Map.drop(model.pricing, [:merge]) == provider.pricing_defaults

    assert model.pricing.merge == "merge_by_id"
  end

  test "declared component roles and rate-group rules survive shared parsing" do
    pricing = %{
      currency: "USD",
      components: [
        %{
          id: "token.input.short",
          role: "rate",
          kind: "token",
          unit: "token",
          per: 1_000_000,
          rate: 1.0,
          rate_group: "input_tokens",
          rate_group_policy: "exactly_one"
        },
        %{
          id: "token.cache_write.1h",
          role: "derived_rate",
          kind: "token",
          unit: "token",
          per: 1_000_000,
          multiplier: 2.0,
          derives_from: "token.input.short",
          rate_group: "cache_write_tokens"
        },
        %{
          id: "pricing.batch",
          role: "modifier",
          kind: "other",
          unit: "other",
          multiplier: 0.5,
          applies_to: ["token.*"]
        }
      ]
    }

    model = Model.new!(%{id: "model", provider: :provider, pricing: pricing})
    provider = Provider.new!(%{id: :provider, pricing_defaults: pricing})

    assert Map.drop(model.pricing, [:merge]) == provider.pricing_defaults
    assert Enum.map(model.pricing.components, & &1.role) == ~w(rate derived_rate modifier)
    assert hd(model.pricing.components).rate_group_policy == "exactly_one"
  end

  test "declared roles reject incompatible fields without rejecting untyped legacy maps" do
    assert Model.new!(%{id: "model", provider: :provider, pricing: @pricing})

    invalid_components = [
      %{id: "rate", role: "rate", unit: "token", per: 1_000_000, multiplier: 2.0},
      %{id: "derived", role: "derived_rate", unit: "token", per: 1_000_000, rate: 1.0},
      %{id: "modifier", role: "modifier", multiplier: 0.5, applies_to: []},
      %{
        id: "grouped",
        role: "rate",
        unit: "token",
        per: 1_000_000,
        rate: 1.0,
        rate_group_policy: "exactly_one"
      }
    ]

    for component <- invalid_components do
      assert {:error, errors} =
               Model.new(%{
                 id: "model",
                 provider: :provider,
                 pricing: %{components: [component]}
               })

      assert errors != []
    end
  end

  test "model-specific merge behavior remains available" do
    model =
      Model.new!(%{
        id: "model",
        provider: :provider,
        pricing: Map.put(@pricing, :merge, "replace")
      })

    assert model.pricing.merge == "replace"
  end

  test "both parents reject the same invalid component payloads" do
    invalid = put_in(@pricing, [:components, Access.at(0), :per], 0)

    assert {:error, model_error} =
             Model.new(%{id: "model", provider: :provider, pricing: invalid})

    assert {:error, provider_error} =
             Provider.new(%{id: :provider, pricing_defaults: invalid})

    assert inspect(model_error) =~ "per"
    assert inspect(provider_error) =~ "per"
  end

  test "legacy conversion exclusions survive model and sparse overlay validation" do
    pricing = Map.put(@pricing, :excluded_cost_components, ["token.reasoning"])
    input = %{id: "model", provider: :provider, pricing: pricing}
    assert Model.new!(input).pricing.excluded_cost_components == ["token.reasoning"]
    assert {:ok, overlay} = Validate.validate_model_overlay(input)
    assert overlay.pricing.excluded_cost_components == ["token.reasoning"]

    for invalid <- [["tool.search"], ["token.*"], "token.reasoning"] do
      assert {:error, _} =
               Model.new(put_in(input, [:pricing, :excluded_cost_components], invalid))
    end
  end
end
