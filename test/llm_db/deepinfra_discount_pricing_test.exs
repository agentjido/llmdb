defmodule LLMDB.DeepinfraDiscountPricingTest do
  use ExUnit.Case, async: true

  alias LLMDB.{Merge, Model, Normalize, Pricing}
  alias LLMDB.Sources.{Local, ModelsDev, Remote}

  @expected %{
    "Qwen/Qwen3.8-27B" => %{input: 0.15, output: 1.875, cache_read: 0.0375},
    "zai-org/GLM-5.3" => %{input: 0.5625, output: 2.5, cache_read: 0.125},
    "deepseek-ai/DeepSeek-V4.1-Flash" => %{input: 0.14, output: 0.42, cache_read: 0.0042},
    "zai-org/GLM-5.3-Flash" => %{input: 0.075, output: 0.25, cache_read: 0.015}
  }
  @discount_end 1_792_540_799

  setup_all do
    {:ok, upstream} =
      Remote.load("https://models.dev/api.json",
        cache_dir: "priv/llm_db/upstream",
        cache_key: "models-dev"
      )

    remote = ModelsDev.transform(upstream)
    {:ok, local} = Local.load(%{dir: "priv/llm_db/local"})

    models =
      remote["deepinfra"].models
      |> Normalize.normalize_models()
      |> Merge.merge_models(Normalize.normalize_models(local["deepinfra"].models), %{})
      |> Enum.filter(&Map.has_key?(@expected, &1.id))
      |> Enum.map(&Model.new!/1)
      |> Pricing.apply_cost_components()
      |> Map.new(&{&1.id, &1})

    %{models: models}
  end

  test "effective prices include the discount once, including cached input", %{models: models} do
    for {id, cost} <- @expected do
      model = Map.fetch!(models, id)
      assert Map.take(model.cost, Map.keys(cost)) == cost
      selected = Pricing.components_for(model, timestamp: @discount_end)
      assert selected.unresolved == []
      assert length(selected.components) == 3
      assert rates(selected.components) == cost
      assert Pricing.validate_components(model.pricing.components) == :ok
      assert Pricing.apply_cost_components([model]) == [model]
      assert model.extra.pricing.discount_already_applied
      assert model.extra.pricing.sources_checked_at == "2026-10-19"
      assert length(model.extra.pricing.source_urls) == 3
    end
  end

  test "GLM Flash selects standard rates after the discount ends", %{models: models} do
    model = models["zai-org/GLM-5.3-Flash"]

    for timestamp <- [@discount_end - 1, @discount_end, @discount_end + 1] do
      selected = Pricing.components_for(model, timestamp: timestamp)
      assert selected.unresolved == []
      assert length(selected.components) == 3

      expected =
        if timestamp <= @discount_end,
          do: @expected[model.id],
          else: %{input: 0.15, output: 0.5, cache_read: 0.03}

      assert rates(selected.components) == expected
    end

    assert model.extra.pricing.discount_ends_at == "2026-10-20T23:59:59Z"
  end

  test "GLM Flash requires a timestamp to select the discount period", %{models: models} do
    selected = Pricing.components_for(models["zai-org/GLM-5.3-Flash"])
    assert selected.components == []
    assert length(selected.unresolved) == 6
  end

  test "packaged snapshot preserves effective prices and discount expiry" do
    snapshot = "priv/llm_db/snapshot.json" |> File.read!() |> Jason.decode!()
    models = snapshot["providers"]["deepinfra"]["models"]

    for {id, cost} <- @expected do
      for {key, rate} <- cost do
        assert models[id]["cost"][Atom.to_string(key)] == rate
      end
    end

    model = models["zai-org/GLM-5.3-Flash"]
    assert model["extra"]["pricing"]["discount_ends_at"] == "2026-10-20T23:59:59Z"
    selected = Pricing.components_for(model, timestamp: @discount_end + 1)
    assert selected.unresolved == []
    assert length(selected.components) == 3

    assert Map.new(selected.components, &{&1["meter"], &1["rate"]}) == %{
             "input_tokens" => 0.15,
             "output_tokens" => 0.5,
             "cache_read_tokens" => 0.03
           }
  end

  defp rates(components) do
    Map.new(components, fn component ->
      key =
        case String.split(component.id, ".") do
          ["token", "input" | _] -> :input
          ["token", "output" | _] -> :output
          ["token", "cache_read" | _] -> :cache_read
        end

      {key, component.rate}
    end)
  end
end
