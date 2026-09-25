defmodule LLMDB.ContextPriceBandsTest do
  use ExUnit.Case, async: true

  alias LLMDB.{Loader, Pricing}

  @cases [
    {:openai, ~w(gpt-5.6 gpt-5.6-sol gpt-5.6-terra gpt-5.6-luna gpt-6-astra gpt-6-sol gpt-6-luna),
     272_000, [api: "responses", service_tier: "default", regional_processing: false]},
    {:google, ~w(gemini-3.1-pro-preview gemini-3.1-pro-preview-customtools), 200_000,
     [api: "generate_content", service_tier: "standard", cache_type: "implicit"]},
    {:xai,
     ~w(grok-4.20-0309-non-reasoning grok-4.20-0309-reasoning grok-4.20-multi-agent-0309 grok-4.3 grok-4.5 grok-4.6 grok-4.7 grok-build-0.1),
     199_999, [api: "responses", service_tier: "default", base_url: "https://api.x.ai/v1"]},
    {:alibaba, ~w(qwen3.7-plus qwen3.6-plus), 256_000,
     [api: "chat", region: "singapore", deployment: "international", cache_mode: "explicit"]},
    {:alibaba, ~w(qwen3.6-max-preview), 128_000,
     [api: "chat", region: "singapore", deployment: "international", cache_mode: "explicit"]}
  ]

  setup_all do
    allow =
      Enum.reduce(@cases, %{}, fn {provider, ids, _, _}, acc ->
        Map.update(acc, provider, ids, &(&1 ++ ids))
      end)

    {:ok, loaded} = Loader.load(allow: allow, deny: %{}, prefer: [], custom: %{})

    %{
      models:
        Map.new(for {provider, models} <- loaded.models, m <- models, do: {{provider, m.id}, m})
    }
  end

  test "packaged tariffs expose complete, exclusive whole-request bands across providers", ctx do
    for {provider, ids, last_short, context} <- @cases, id <- ids do
      model = Map.fetch!(ctx.models, {provider, id})
      assert model.pricing.currency == "USD"
      short = token_rates(model, Keyword.put(context, :input_tokens, last_short))
      long = token_rates(model, Keyword.put(context, :input_tokens, last_short + 1))

      for meter <- ~w(input_tokens output_tokens cache_read_tokens) do
        assert Map.has_key?(short, meter), "#{provider}:#{id} missing #{meter}"
        assert long[meter] > short[meter], "#{provider}:#{id} missing #{meter} price cliff"
      end

      # Cached input still counts toward the threshold, and output volume cannot
      # choose another input band. Billing quantities are a separate concern.
      assert token_rates(
               model,
               Keyword.merge(context,
                 input_tokens: last_short + 1,
                 cache_read_tokens: last_short,
                 output_tokens: 1
               )
             ) == long

      assert token_rates(
               model,
               Keyword.merge(context, input_tokens: last_short, output_tokens: 100_000)
             ) == short

      [enriched] = Pricing.apply_cost_components([model])

      assert Enum.sort_by(enriched.pricing.components, & &1.id) ==
               Enum.sort_by(model.pricing.components, & &1.id)
    end
  end

  test "packaged legacy summaries cannot select a price when prompt size is unknown", ctx do
    for {provider, ids, _, context} <- @cases, id <- ids, missing <- [nil, :omitted] do
      model = Map.fetch!(ctx.models, {provider, id})

      context =
        if missing == :omitted, do: context, else: Keyword.put(context, :input_tokens, nil)

      selection = Pricing.components_for(model, context)
      refute Enum.any?(selection.components, &(&1.kind == "token"))
      assert Enum.any?(selection.unresolved, &(&1.kind == "token"))
    end
  end

  defp token_rates(model, context) do
    selection = Pricing.components_for(model, context)
    refute Enum.any?(selection.unresolved, &(&1.kind in ["token", "other"]))
    rates = Enum.filter(selection.components, &(&1.kind == "token"))
    assert length(Enum.uniq_by(rates, & &1.meter)) == length(rates)

    for rate <- rates do
      assert rate.charge_scope == "full_request"
      assert rate.mode == "standard"
      assert rate.source in ["provider_api", "provider_docs"]
      assert rate.per == 1_000_000
    end

    Map.new(rates, &{&1.meter, &1.rate})
  end
end
