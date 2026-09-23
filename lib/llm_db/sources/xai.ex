defmodule LLMDB.Sources.XAI do
  @moduledoc """
  Remote source for xAI (Grok) models (https://api.x.ai/v1/models).

  - `pull/1` fetches data from xAI API and caches locally
  - `load/1` reads from cached file (no network call)

  ## Options

  - `:url` - API endpoint (default: "https://api.x.ai/v1/models")
  - `:api_key` - xAI API key (required, or set `XAI_API_KEY` env var)
  - `:region` - Optional regional endpoint (`:us_east_1` or `:eu_west_1`)
  - `:req_opts` - Additional Req options for testing

  ## Configuration

  Cache directory can be configured in application config:

      config :llm_db,
        xai_cache_dir: "priv/llm_db/remote"

  Default: `"priv/llm_db/remote"`

  ## Regional Endpoints

  You can use regional endpoints for data residency:

  - `:us_east_1` - `https://us-east-1.api.x.ai/v1/models`
  - `:eu_west_1` - `https://eu-west-1.api.x.ai/v1/models`

  ## Usage

      # Pull remote data and cache (requires API key)
      mix llm_db.pull --source xai

      # Pull with regional endpoint
      mix llm_db.pull --source xai --region eu_west_1

      # Load from cache
      {:ok, data} = XAI.load(%{})
  """

  @behaviour LLMDB.Source

  alias LLMDB.Sources.Remote

  @default_url "https://api.x.ai/v1/models"
  @default_cache_dir "priv/llm_db/remote"

  @regional_endpoints %{
    us_east_1: "https://us-east-1.api.x.ai/v1/models",
    eu_west_1: "https://eu-west-1.api.x.ai/v1/models"
  }

  @impl true
  def pull(opts) do
    api_key = get_api_key(opts)

    if is_nil(api_key) or api_key == "" do
      {:error, :no_api_key}
    else
      do_pull(opts, api_key)
    end
  end

  defp do_pull(opts, api_key) do
    url = get_url(opts)

    Remote.pull(url,
      cache_dir: get_cache_dir(),
      cache_key: "xai",
      headers: build_headers(api_key),
      req_opts: Map.get(opts, :req_opts, [])
    )
  end

  @impl true
  def load(opts) do
    url = get_url(opts)

    case Remote.load(url, cache_dir: get_cache_dir(), cache_key: "xai") do
      {:ok, decoded} -> {:ok, transform(decoded)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Transforms xAI API response to canonical Zoi format.

  xAI uses OpenAI-compatible format.

  ## Input Format (xAI)

  ```json
  {
    "object": "list",
    "data": [
      {
        "id": "grok-4-fast-reasoning",
        "object": "model",
        "created": 1234567890,
        "owned_by": "xai"
      }
    ]
  }
  ```

  ## Output Format (Canonical Zoi)

  ```elixir
  %{
    "xai" => %{
      id: :xai,
      name: "xAI",
      models: [
        %{
          id: "grok-4-fast-reasoning",
          provider: :xai,
          extra: %{
            created: 1234567890,
            owned_by: "xai"
          }
        }
      ]
    }
  }
  ```
  """
  def transform(content) when is_map(content) do
    models_list =
      content
      |> Map.get("data", [])
      |> Enum.map(&transform_model/1)

    %{
      "xai" => %{
        id: :xai,
        name: "xAI",
        models: models_list
      }
    }
  end

  defp transform_model(model) do
    %{
      id: model["id"],
      provider: :xai,
      extra:
        %{}
        |> maybe_put(:created, model["created"])
        |> maybe_put(:owned_by, model["owned_by"])
        |> maybe_put(:long_context_threshold, model["long_context_threshold"])
    }
    |> maybe_put(:aliases, model["aliases"])
    |> maybe_put(:limits, limits_from_model(model))
    |> maybe_put(:cost, cost_from_model(model))
    |> maybe_put(:pricing, pricing_from_model(model))
  end

  defp limits_from_model(model) do
    %{}
    |> maybe_put(:context, model["context_length"])
    |> empty_to_nil()
  end

  defp cost_from_model(model) do
    %{}
    |> maybe_put(:input, token_price(model["prompt_text_token_price"]))
    |> maybe_put(:cache_read, token_price(model["cached_prompt_text_token_price"]))
    |> maybe_put(:output, token_price(model["completion_text_token_price"]))
    |> maybe_put(:image, token_price(model["prompt_image_token_price"]))
    |> empty_to_nil()
  end

  defp pricing_from_model(%{"long_context_threshold" => threshold} = model)
       when is_integer(threshold) and threshold > 0 do
    components =
      for {id, meter, field} <- [
            {"token.input", "input_tokens", "prompt_text_token_price"},
            {"token.cache_read", "cache_read_tokens", "cached_prompt_text_token_price"},
            {"token.output", "output_tokens", "completion_text_token_price"}
          ],
          {suffix, comparison} <- [{"", :lt}, {".long_context", :gte}],
          key = if(suffix == "", do: field, else: field <> "_long_context"),
          rate <- [token_price(model[key])],
          is_number(rate) or suffix == "" do
        # An unpriced base component still constrains its context. Otherwise a
        # lower-precedence legacy cost could become an unconditional fallback.
        %{
          id: id <> suffix,
          kind: "token",
          unit: "token",
          per: 1_000_000,
          meter: meter,
          applies_when: %{input_tokens: %{comparison => threshold}},
          mode: "standard",
          charge_scope: "full_request",
          source: "provider_api",
          notes:
            "Prompt length selects the rate for all tokens in the request; " <>
              "the long-context threshold is inclusive. See https://docs.x.ai/developers/pricing."
        }
        |> maybe_put(:rate, rate)
      end

    %{currency: "USD", merge: "merge_by_id", components: components}
  end

  defp pricing_from_model(_model), do: nil

  defp token_price(nil), do: nil
  defp token_price(price) when is_number(price), do: price / 10_000
  defp token_price(_price), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp empty_to_nil(map) when map_size(map) == 0, do: nil
  defp empty_to_nil(map), do: map

  defp get_url(opts) do
    case Map.get(opts, :region) do
      nil ->
        Map.get(opts, :url, @default_url)

      region when is_atom(region) ->
        Map.get(@regional_endpoints, region) || @default_url

      region when is_binary(region) ->
        region_atom = String.to_existing_atom(region)
        Map.get(@regional_endpoints, region_atom) || @default_url
    end
  end

  defp get_api_key(opts) do
    Map.get(opts, :api_key) || System.get_env("XAI_API_KEY")
  end

  defp get_cache_dir do
    Application.get_env(:llm_db, :xai_cache_dir, @default_cache_dir)
  end

  defp build_headers(api_key) do
    [{"authorization", "Bearer #{api_key}"}]
  end
end
