defmodule LLMDB.PricingTest do
  use ExUnit.Case, async: true

  alias LLMDB.Pricing

  test "builds pricing components from cost when missing" do
    model = %LLMDB.Model{
      id: "m1",
      provider: :test,
      cost: %{input: 1.0, output: 2.0, cache_read: 0.5, cache_write: 0.8}
    }

    [updated] = Pricing.apply_cost_components([model])

    ids = Enum.map(updated.pricing.components, & &1.id) |> Enum.sort()

    assert ids == [
             "token.cache_read",
             "token.cache_write",
             "token.input",
             "token.output"
           ]
  end

  test "keeps explicit pricing component overrides over cost-derived components" do
    model = %LLMDB.Model{
      id: "m1",
      provider: :test,
      cost: %{input: 1.0, output: 2.0},
      pricing: %{
        components: [
          %{id: "token.output", kind: "token", unit: "token", per: 1_000_000, rate: 3.0}
        ]
      }
    }

    [updated] = Pricing.apply_cost_components([model])

    output =
      Enum.find(updated.pricing.components, fn component -> component.id == "token.output" end)

    assert output.rate == 3.0
  end

  test "excluded legacy conversions preserve explicit rates and the original summary" do
    explicit = %{
      id: "token.output",
      kind: "token",
      unit: "token",
      per: 10_000,
      rate: 24.0,
      applies_when: %{pricing_period: "peak"}
    }

    model = %LLMDB.Model{
      id: "credits",
      provider: :test,
      cost: %{output: 0, reasoning: 4.0},
      pricing: %{
        currency: "credits",
        excluded_cost_components: ["token.output", "token.reasoning"],
        components: [explicit]
      }
    }

    [updated] = Pricing.apply_cost_components([model])
    assert updated.cost == model.cost
    assert updated.pricing.currency == "credits"
    assert updated.pricing.components == [explicit]
    assert Pricing.apply_cost_components([updated]) == [updated]
    assert Pricing.components_for(updated).components == []
  end

  test "JSON exclusions suppress only the named legacy components" do
    model = %{
      "cost" => %{"input" => 1.0, "output" => 2.0, "reasoning" => 2.0},
      "pricing" => %{"excluded_cost_components" => ["token.reasoning"]}
    }

    [updated] = Pricing.apply_cost_components([model])
    assert Enum.map(updated.pricing.components, & &1.id) == ["token.input", "token.output"]
  end

  test "preserves explicit conditional components when converting legacy cost" do
    model = %LLMDB.Model{
      id: "m1",
      provider: :test,
      cost: %{input: 5.0},
      pricing: %{
        components: [
          %{
            id: "token.input.long_context",
            kind: "token",
            unit: "token",
            per: 1_000_000,
            rate: 10.0,
            applies_when: %{input_tokens: %{gt: 272_000}},
            charge_scope: "full_request"
          }
        ]
      }
    }

    [updated] = Pricing.apply_cost_components([model])
    components = Map.new(updated.pricing.components, &{&1.id, &1})

    assert components["token.input"].rate == 5.0
    assert components["token.input.long_context"].applies_when.input_tokens.gt == 272_000
    assert components["token.input.long_context"].charge_scope == "full_request"
  end

  test "applies provider defaults when model has no pricing" do
    provider = %LLMDB.Provider{
      id: :test,
      pricing_defaults: %{
        currency: "USD",
        components: [
          %{id: "token.input", kind: "token", unit: "token", per: 1_000_000, rate: 1.0}
        ]
      }
    }

    model = %LLMDB.Model{id: "m1", provider: :test, pricing: nil}

    [updated] = Pricing.apply_provider_defaults([provider], [model])
    assert updated.pricing.currency == "USD"
    assert [%{id: "token.input"}] = updated.pricing.components
  end

  test "merges provider defaults with model overrides by id" do
    provider = %LLMDB.Provider{
      id: :test,
      pricing_defaults: %{
        currency: "USD",
        components: [
          %{id: "token.input", kind: "token", unit: "token", per: 1_000_000, rate: 1.0},
          %{id: "token.output", kind: "token", unit: "token", per: 1_000_000, rate: 2.0}
        ]
      }
    }

    model = %LLMDB.Model{
      id: "m1",
      provider: :test,
      pricing: %{
        merge: "merge_by_id",
        components: [
          %{id: "token.output", kind: "token", unit: "token", per: 1_000_000, rate: 3.0}
        ]
      }
    }

    [updated] = Pricing.apply_provider_defaults([provider], [model])

    rates =
      updated.pricing.components
      |> Enum.map(fn c -> {c.id, c.rate} end)
      |> Map.new()

    assert rates["token.input"] == 1.0
    assert rates["token.output"] == 3.0
  end

  test "replace merge keeps only model pricing" do
    provider = %LLMDB.Provider{
      id: :test,
      pricing_defaults: %{
        currency: "USD",
        components: [
          %{id: "token.input", kind: "token", unit: "token", per: 1_000_000, rate: 1.0}
        ]
      }
    }

    model = %LLMDB.Model{
      id: "m1",
      provider: :test,
      pricing: %{
        merge: "replace",
        components: [
          %{id: "token.output", kind: "token", unit: "token", per: 1_000_000, rate: 3.0}
        ]
      }
    }

    [updated] = Pricing.apply_provider_defaults([provider], [model])

    assert [%{id: "token.output"}] = updated.pricing.components
  end

  test "components_for returns an empty selection when pricing is missing" do
    assert %{components: [], unresolved: []} =
             Pricing.components_for(%LLMDB.Model{id: "m1", provider: :test})

    assert %{components: [], unresolved: []} = Pricing.components_for(%{pricing: nil})
    assert %{components: [], unresolved: []} = Pricing.components_for(%{}, nil)
  end

  test "components_for selects matching components and reports incomplete conditions" do
    model = %{
      pricing: %{
        components: [
          %{id: "token.input", kind: "token", rate: 5.0},
          %{
            id: "token.input.long_context",
            kind: "token",
            rate: 10.0,
            applies_when: %{input_tokens: %{gt: 272_000}}
          },
          %{
            id: "token.input.batch",
            kind: "token",
            rate: 2.5,
            applies_when: %{api: "batch"}
          },
          %{
            id: "pricing.data_residency",
            kind: "other",
            multiplier: 1.1,
            applies_to: ["token.*"],
            applies_when: %{inference_geo: true}
          }
        ]
      }
    }

    result = Pricing.components_for(model, input_tokens: 900_000)

    assert Enum.map(result.components, & &1.id) == ["token.input", "token.input.long_context"]
    assert Enum.map(result.unresolved, & &1.id) == ["token.input.batch", "pricing.data_residency"]
  end

  test "components_for respects excludes_when" do
    model = %{
      pricing: %{
        components: [
          %{id: "tool.web_search", kind: "tool", excludes_when: %{api: "batch"}}
        ]
      }
    }

    assert %{components: [], unresolved: []} = Pricing.components_for(model, api: "batch")

    assert %{components: [%{id: "tool.web_search"}], unresolved: []} =
             Pricing.components_for(model, api: "responses")
  end

  test "components_for treats empty condition maps as absent conditions" do
    model = %{
      pricing: %{
        components: [
          %{id: "token.input", applies_when: %{}},
          %{id: "token.output", excludes_when: %{}}
        ]
      }
    }

    assert %{components: components, unresolved: []} = Pricing.components_for(model)
    assert Enum.map(components, & &1.id) == ["token.input", "token.output"]
  end

  test "a known non-match excludes a component even when its exclusion is unknown" do
    component = %{
      id: "pricing.flex",
      applies_when: %{service_tier: "flex"},
      excludes_when: %{api: "batch"}
    }

    model = %{pricing: %{components: [component]}}

    assert %{components: [], unresolved: []} =
             Pricing.components_for(model, service_tier: "default")

    assert %{components: [], unresolved: [^component]} =
             Pricing.components_for(model, service_tier: "flex")

    assert %{components: [], unresolved: []} = Pricing.components_for(model, api: "batch")
  end

  test "nil request values remain unresolved for scalar, nested, and numeric conditions" do
    for {key, expected} <- [
          {:cache_ttl, "1h"},
          {:regional_processing, true},
          {:request_body, %{speed: "fast"}},
          {:input_tokens, %{gt: 272_000}}
        ] do
      component = %{id: "conditional", applies_when: %{key => expected}}
      model = %{pricing: %{components: [component]}}

      assert %{components: [], unresolved: [^component]} =
               Pricing.components_for(model, %{key => nil})
    end
  end

  test "JSON string keys match nested atom-keyed context without creating atoms" do
    key = "unknown-pricing-header-#{System.unique_integer([:positive])}"

    component = %{
      "id" => "pricing.fast",
      "applies_when" => %{
        "request_body" => %{"speed" => "fast"},
        "request_headers" => %{key => "on"}
      }
    }

    model = %{"pricing" => %{"components" => [component]}}

    assert %{components: [^component], unresolved: []} =
             Pricing.components_for(model,
               request_body: %{speed: "fast"},
               request_headers: %{key => "on"}
             )

    assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
  end
end
