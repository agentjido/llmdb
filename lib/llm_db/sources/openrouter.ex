defmodule LLMDB.Sources.OpenRouter do
  @moduledoc """
  Remote source for OpenRouter metadata (https://openrouter.ai/api/v1/models?output_modalities=all).

  - `pull/1` fetches data via Req and caches locally
  - `load/1` reads from cached file (no network call)

  ## Options

  - `:url` - API endpoint (default: "https://openrouter.ai/api/v1/models")
  - `:req_opts` - Additional Req options for testing (e.g., `[plug: test_plug]`)
  - `:api_key` - OpenRouter API key (optional for public model list)

  ## Configuration

  Cache directory can be configured in application config:

      config :llm_db,
        openrouter_cache_dir: "priv/llm_db/upstream"

  Default: `"priv/llm_db/upstream"`

  ## Usage

      # Pull remote data and cache
      mix llm_db.pull

      # Load from cache
      {:ok, data} = OpenRouter.load(%{})
  """

  @behaviour LLMDB.Source

  alias LLMDB.Sources.Remote

  @default_url "https://openrouter.ai/api/v1/models?output_modalities=all"
  @default_cache_dir "priv/llm_db/upstream"

  @impl true
  def pull(opts) do
    url = Map.get(opts, :url, @default_url)

    auth_headers =
      case Map.get(opts, :api_key) do
        nil -> []
        key -> [{"authorization", "Bearer #{key}"}]
      end

    Remote.pull(url,
      cache_dir: get_cache_dir(),
      cache_key: "openrouter",
      headers: auth_headers,
      req_opts: Map.get(opts, :req_opts, [])
    )
  end

  @impl true
  def load(opts) do
    url = Map.get(opts, :url, @default_url)

    case Remote.load(url, cache_dir: get_cache_dir(), cache_key: "openrouter") do
      {:ok, decoded} -> {:ok, transform(decoded)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Transforms OpenRouter JSON format to canonical Zoi format.

  ## Input Format (OpenRouter)

  ```json
  {
    "data": [
      {
        "id": "openai/gpt-4",
        "name": "GPT-4",
        "context_length": 128000,
        "pricing": {
          "prompt": "0.00003",
          "completion": "0.00006"
        },
        "architecture": {
          "modality": "text->text",
          "tokenizer": "GPT",
          "instruct_type": "chatml"
        },
        "top_provider": {
          "max_completion_tokens": 16384
        },
        ...
      }
    ]
  }
  ```

  ## Output Format (Canonical Zoi)

  ```elixir
  %{
    "openrouter" => %{
      id: :openrouter,
      name: "OpenRouter",
      models: [
        %{
          id: "openai/gpt-4",
          provider: :openrouter,
          name: "GPT-4",
          limits: %{context: 128000, output: 16384},
          cost: %{input: 0.03, output: 0.06},
          pricing: %{
            components: [
              %{
                id: "tool.web_search",
                kind: "tool",
                tool: "web_search",
                unit: "call",
                per: 1,
                rate: 0.01
              }
            ]
          },
          ...
        },
        %{
          id: "perplexity/sonar-pro",
          provider: :openrouter,
          name: "Perplexity: Sonar Pro",
          ...
        }
      ]
    }
  }
  ```

  Main transformations:
  - Keep model IDs exactly as provided by OpenRouter (e.g., `perplexity/sonar-pro`)
  - All models registered under `:openrouter` provider only
  - Transform pricing strings to floats (per 1M tokens)
  - Map context_length → limits.context
  - Map top_provider.max_completion_tokens → limits.output
  - Extract modality information

  ## Provider Separation

  OpenRouter models are distinct from native provider models. For example:
  - `openrouter:perplexity/sonar-pro` - accessed via OpenRouter API
  - `perplexity:sonar-pro` - accessed via native Perplexity API (from Perplexity source)

  These are separate entries with potentially different pricing, limits, and capabilities.
  Model IDs may contain `/` which is part of the ID string, not a provider delimiter.
  """
  def transform(content) when is_map(content) do
    models = Map.get(content, "data", [])

    {canonical_models, resolved_alias_ids} =
      models
      |> Enum.map(&transform_model/1)
      |> consolidate_alias_targets(models)

    %{
      "openrouter" => %{
        id: :openrouter,
        name: "OpenRouter",
        exclude_models: resolved_alias_ids,
        models: canonical_models
      }
    }
  end

  # Private helpers

  defp consolidate_alias_targets(canonical_models, source_models) do
    model_ids = MapSet.new(canonical_models, & &1.id)

    direct_targets =
      Enum.reduce(source_models, %{}, fn source_model, direct_targets ->
        alias_id = source_model["id"]
        target_id = get_in(source_model, ["alias_target", "slug"])

        if is_binary(alias_id) and is_binary(target_id) and alias_id != target_id and
             MapSet.member?(model_ids, target_id) do
          Map.put(direct_targets, alias_id, target_id)
        else
          direct_targets
        end
      end)

    {aliases_by_target, resolved_alias_ids} =
      Enum.reduce(source_models, {%{}, []}, fn source_model,
                                               {aliases_by_target, resolved_alias_ids} ->
        alias_id = source_model["id"]

        case resolve_alias_target(alias_id, direct_targets) do
          {:ok, target_id} ->
            {
              Map.update(aliases_by_target, target_id, [alias_id], &[alias_id | &1]),
              [alias_id | resolved_alias_ids]
            }

          :error ->
            {aliases_by_target, resolved_alias_ids}
        end
      end)

    resolved_alias_id_set = MapSet.new(resolved_alias_ids)

    models =
      canonical_models
      |> Enum.reject(&MapSet.member?(resolved_alias_id_set, &1.id))
      |> Enum.map(fn model ->
        case Map.get(aliases_by_target, model.id) do
          nil ->
            model

          aliases ->
            Map.update(model, :aliases, Enum.reverse(aliases), fn current_aliases ->
              Enum.uniq(current_aliases ++ Enum.reverse(aliases))
            end)
        end
      end)

    {models, Enum.reverse(resolved_alias_ids)}
  end

  defp resolve_alias_target(alias_id, direct_targets) when is_binary(alias_id) do
    case Map.fetch(direct_targets, alias_id) do
      {:ok, target_id} ->
        follow_alias_target(target_id, direct_targets, MapSet.new([alias_id]))

      :error ->
        :error
    end
  end

  defp resolve_alias_target(_alias_id, _direct_targets), do: :error

  defp follow_alias_target(target_id, direct_targets, visited) do
    if MapSet.member?(visited, target_id) do
      :error
    else
      case Map.fetch(direct_targets, target_id) do
        {:ok, next_target_id} ->
          follow_alias_target(next_target_id, direct_targets, MapSet.put(visited, target_id))

        :error ->
          {:ok, target_id}
      end
    end
  end

  defp get_cache_dir do
    Application.get_env(:llm_db, :openrouter_cache_dir, @default_cache_dir)
  end

  # Fields we explicitly map to canonical Zoi fields
  @mapped_fields ~w[
    id name description context_length pricing architecture
    top_provider supported_parameters default_parameters
    per_request_limits created canonical_slug
  ]

  defp transform_model(model) do
    # Keep the full OpenRouter model ID (including any "/")
    # All models are registered under :openrouter provider
    model_id = model["id"]

    canonical =
      %{
        id: model_id,
        provider: :openrouter,
        name: model["name"]
      }
      |> put_if_present(:description, model["description"])
      |> put_if_present(:release_date, parse_timestamp(model["created"]))
      |> map_limits(model)
      |> map_cost(model["pricing"])
      |> map_pricing(model["pricing"])
      |> map_modalities(model["architecture"])
      |> map_capabilities(model)
      |> map_extra(model)

    canonical
  end

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(ts) when is_integer(ts) do
    DateTime.from_unix!(ts)
    |> DateTime.to_date()
    |> Date.to_iso8601()
  end

  defp parse_timestamp(_), do: nil

  defp map_limits(model, source) do
    limits =
      %{}
      |> put_if_valid_limit(:context, source["context_length"])
      |> put_if_valid_limit(:output, get_in(source, ["top_provider", "max_completion_tokens"]))

    if map_size(limits) > 0 do
      Map.put(model, :limits, limits)
    else
      model
    end
  end

  defp map_cost(model, nil), do: model

  defp map_cost(model, pricing) when is_map(pricing) do
    cost =
      %{}
      |> put_cost_if_present(:input, pricing["prompt"])
      |> put_cost_if_present(:output, pricing["completion"])
      |> put_cost_if_present(:request, pricing["request"])
      |> put_cost_if_present(:cache_read, pricing["input_cache_read"])
      |> put_cost_if_present(:cache_write, pricing["input_cache_write"])
      |> put_cost_if_present(:reasoning, pricing["internal_reasoning"])
      |> put_cost_if_present(:image, pricing["image"])
      |> put_cost_if_present(:audio, pricing["audio"])
      |> put_cost_if_present(:input_audio, pricing["input_audio"])
      |> put_cost_if_present(:output_audio, pricing["output_audio"])
      |> put_cost_if_present(:input_video, pricing["input_video"])
      |> put_cost_if_present(:output_video, pricing["output_video"])

    if map_size(cost) > 0 do
      Map.put(model, :cost, cost)
    else
      model
    end
  end

  defp put_cost_if_present(map, _key, nil), do: map

  defp put_cost_if_present(map, key, value) when is_binary(value) do
    case parse_price(value) do
      nil -> map
      float_val -> Map.put(map, key, Float.round(float_val * 1_000_000, 6))
    end
  end

  defp put_cost_if_present(map, key, value) when is_number(value) do
    Map.put(map, key, Float.round(value * 1_000_000, 6))
  end

  defp put_cost_if_present(map, _key, _value), do: map

  defp parse_price(value) when is_binary(value) do
    case Float.parse(value) do
      {float_val, _} -> float_val
      :error -> nil
    end
  end

  defp parse_price(value) when is_number(value), do: value
  defp parse_price(_value), do: nil

  defp map_pricing(model, nil), do: model

  defp map_pricing(model, pricing) when is_map(pricing) do
    components =
      []
      |> put_tool_component_if_present("tool.web_search", "web_search", pricing["web_search"])

    if components == [] do
      model
    else
      Map.put(model, :pricing, %{
        currency: "USD",
        components: components
      })
    end
  end

  defp put_tool_component_if_present(components, _id, _tool, nil), do: components

  defp put_tool_component_if_present(components, id, tool, value) do
    case parse_price(value) do
      nil ->
        components

      rate ->
        components ++
          [
            %{
              id: id,
              kind: "tool",
              tool: tool,
              unit: "call",
              per: 1,
              rate: rate
            }
          ]
    end
  end

  defp map_modalities(model, nil), do: model

  defp map_modalities(model, arch) when is_map(arch) do
    case Map.get(arch, "modality") do
      nil ->
        model

      modality_str when is_binary(modality_str) ->
        modalities = parse_modality_string(modality_str)

        if map_size(modalities) > 0 do
          Map.put(model, :modalities, modalities)
        else
          model
        end

      _ ->
        model
    end
  end

  defp parse_modality_string(str) do
    case String.split(str, "->") do
      [input, output] ->
        %{
          input: parse_modality_list(input),
          output: parse_modality_list(output)
        }

      _ ->
        %{}
    end
  end

  defp parse_modality_list(str) do
    str
    |> String.split("+")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.to_atom/1)
  end

  defp map_capabilities(model, source) do
    capabilities = %{}

    capabilities =
      if Enum.member?(Map.get(source, "supported_parameters", []), "tools") do
        Map.put(capabilities, :tools, %{enabled: true})
      else
        capabilities
      end

    output_modalities = get_in(source, ["architecture", "output_modalities"])

    capabilities =
      if is_list(output_modalities) and
           Enum.any?(output_modalities, &(&1 in ["embedding", "embeddings"])) do
        Map.put(capabilities, :embeddings, true)
      else
        capabilities
      end

    if map_size(capabilities) > 0 do
      Map.put(model, :capabilities, capabilities)
    else
      model
    end
  end

  defp map_extra(model, source) do
    extra =
      source
      |> Map.drop(@mapped_fields)
      |> Enum.reduce(%{}, fn {key, value}, acc ->
        atom_key = String.to_atom(key)
        Map.put(acc, atom_key, value)
      end)

    if map_size(extra) > 0 do
      Map.put(model, :extra, extra)
    else
      model
    end
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp put_if_valid_limit(map, _key, nil), do: map
  defp put_if_valid_limit(map, _key, 0), do: map

  defp put_if_valid_limit(map, key, value) when is_integer(value) and value > 0 do
    Map.put(map, key, value)
  end

  defp put_if_valid_limit(map, _key, _value), do: map
end
