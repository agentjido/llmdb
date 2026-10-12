defmodule LLMDB.Sources.Anthropic do
  @moduledoc """
  Remote source for Anthropic models (https://api.anthropic.com/v1/models).

  - `pull/1` fetches data from Anthropic API and caches locally
  - `load/1` reads from cached file (no network call)

  ## Options

  - `:url` - API endpoint (default: "https://api.anthropic.com/v1/models")
  - `:api_key` - Anthropic API key (required, or set `ANTHROPIC_API_KEY` env var)
  - `:anthropic_version` - API version (default: "2023-06-01")
  - `:beta` - Optional beta versions list
  - `:limit` - Items per page (1-1000, default: 1000 to fetch all)
  - `:req_opts` - Additional Req options for testing

  ## Configuration

  Cache directory can be configured in application config:

      config :llm_db,
        anthropic_cache_dir: "priv/llm_db/remote"

  Default: `"priv/llm_db/remote"`

  ## Usage

      # Pull remote data and cache (requires API key)
      mix llm_db.pull --source anthropic

      # Load from cache
      {:ok, data} = Anthropic.load(%{})
  """

  @behaviour LLMDB.Source

  alias LLMDB.Sources.Remote

  @default_url "https://api.anthropic.com/v1/models"
  @default_cache_dir "priv/llm_db/remote"
  @default_version "2023-06-01"
  @effort_order ~w[low medium high xhigh max]
  @thinking_type_order ~w[disabled enabled adaptive]

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
    url = Map.get(opts, :url, @default_url)
    req_opts = Map.get(opts, :req_opts, [])

    headers = build_headers(api_key, opts)
    headers = headers ++ Keyword.get(req_opts, :headers, [])
    req_opts = Keyword.put(req_opts, :headers, headers)

    limit = Map.get(opts, :limit, 1000)
    all_models = fetch_all_pages(url, req_opts, limit, [])

    case all_models do
      {:ok, models} ->
        Remote.store(url, %{"data" => models},
          cache_dir: get_cache_dir(),
          cache_key: "anthropic"
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def load(opts) do
    url = Map.get(opts, :url, @default_url)

    case Remote.load(url, cache_dir: get_cache_dir(), cache_key: "anthropic") do
      {:ok, decoded} -> {:ok, transform(decoded)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Transforms Anthropic API response to canonical Zoi format.

  ## Input Format (Anthropic)

  ```json
  {
    "data": [
      {
        "id": "claude-sonnet-4-20250514",
        "type": "model",
        "display_name": "Claude Sonnet 4",
        "created_at": "2025-02-19T00:00:00Z"
      }
    ]
  }
  ```

  ## Output Format (Canonical Zoi)

  ```elixir
  %{
    "anthropic" => %{
      id: :anthropic,
      name: "Anthropic",
      models: [
        %{
          id: "claude-sonnet-4-20250514",
          provider: :anthropic,
          name: "Claude Sonnet 4",
          extra: %{
            type: "model",
            created_at: "2025-02-19T00:00:00Z"
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
      "anthropic" => %{
        id: :anthropic,
        name: "Anthropic",
        models: models_list
      }
    }
  end

  @mapped_fields ~w[
    id display_name created_at max_input_tokens max_tokens capabilities
  ]

  defp transform_model(model) do
    model = supplement_thinking_types(model)

    %{
      id: model["id"],
      provider: :anthropic
    }
    |> put_if_present(:name, model["display_name"])
    |> put_if_present(:release_date, parse_date(model["created_at"]))
    |> map_limits(model)
    |> map_modalities(model["capabilities"])
    |> map_capabilities(model["capabilities"])
    |> map_extra(model)
  end

  # The Models API currently omits this documented Sonnet 5.5 thinking mode.
  # https://platform.claude.com/docs/en/models/sonnet-5-5/whats-new-sonnet-5-5
  defp supplement_thinking_types(
         %{"id" => "claude-sonnet-5-5", "capabilities" => capabilities} = model
       )
       when is_map(capabilities) do
    thinking = Map.get(capabilities, "thinking") || %{}
    types = Map.get(thinking, "types") || %{}
    types = Map.put(types, "between_tools", %{"supported" => true})
    thinking = thinking |> Map.put("types", types) |> Map.put("supported", true)
    Map.put(model, "capabilities", Map.put(capabilities, "thinking", thinking))
  end

  defp supplement_thinking_types(model), do: model

  defp parse_date(nil), do: nil

  defp parse_date(datetime) when is_binary(datetime) do
    case DateTime.from_iso8601(datetime) do
      {:ok, parsed, _offset} -> parsed |> DateTime.to_date() |> Date.to_iso8601()
      {:error, _reason} -> nil
    end
  end

  defp parse_date(_datetime), do: nil

  defp map_limits(model, source) do
    limits =
      %{}
      |> put_if_valid_limit(:context, source["max_input_tokens"])
      |> put_if_valid_limit(:input, source["max_input_tokens"])
      |> put_if_valid_limit(:output, source["max_tokens"])

    if map_size(limits) > 0 do
      Map.put(model, :limits, limits)
    else
      model
    end
  end

  defp map_modalities(model, capabilities) when is_map(capabilities) do
    input =
      [:text]
      |> maybe_add_modality(:image, supported?(capabilities, "image_input"))
      |> maybe_add_modality(:pdf, supported?(capabilities, "pdf_input"))

    Map.put(model, :modalities, %{input: input, output: [:text]})
  end

  defp map_modalities(model, _capabilities), do: model

  defp map_capabilities(model, capabilities) when is_map(capabilities) do
    canonical =
      %{}
      |> maybe_put_capability(
        :reasoning,
        reasoning_capability(capabilities),
        reasoning_supported?(capabilities)
      )
      |> maybe_put_capability(
        :json,
        %{schema: true},
        supported?(capabilities, "structured_outputs")
      )
      |> maybe_put_capability(:batch, %{supported: true}, supported?(capabilities, "batch"))
      |> maybe_put_capability(
        :citations,
        %{supported: true},
        supported?(capabilities, "citations")
      )
      |> maybe_put_capability(
        :code_execution,
        %{supported: true},
        supported?(capabilities, "code_execution")
      )
      |> maybe_put_capability(
        :context_management,
        context_management_capability(capabilities["context_management"]),
        supported?(capabilities, "context_management")
      )

    if map_size(canonical) > 0 do
      Map.put(model, :capabilities, canonical)
    else
      model
    end
  end

  defp map_capabilities(model, _capabilities), do: model

  defp map_extra(model, source) do
    extra =
      source
      |> Map.drop(@mapped_fields)
      |> Enum.reduce(%{}, fn {k, v}, acc -> Map.put(acc, String.to_atom(k), v) end)
      |> put_if_present(:provider_capabilities, source["capabilities"])

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

  defp maybe_add_modality(modalities, modality, true), do: modalities ++ [modality]
  defp maybe_add_modality(modalities, _modality, _supported), do: modalities

  defp maybe_put_capability(capabilities, key, value, true),
    do: Map.put(capabilities, key, value)

  defp maybe_put_capability(capabilities, _key, _value, _supported), do: capabilities

  defp supported?(capabilities, name) do
    match?(%{"supported" => true}, Map.get(capabilities, name))
  end

  defp reasoning_supported?(capabilities) do
    supported?(capabilities, "effort") or supported?(capabilities, "thinking")
  end

  defp reasoning_capability(capabilities) do
    %{
      enabled: true
    }
    |> maybe_put(:effort, effort_capability(capabilities["effort"]))
    |> maybe_put(:thinking, thinking_capability(capabilities["thinking"]))
  end

  defp effort_capability(effort) when is_map(effort) do
    values = supported_child_names(effort, @effort_order)

    if supported?(%{"effort" => effort}, "effort") or values != [] do
      %{supported: true, values: values}
    end
  end

  defp effort_capability(_effort), do: nil

  defp thinking_capability(thinking) when is_map(thinking) do
    types = supported_child_names(thinking["types"], @thinking_type_order)

    if supported?(%{"thinking" => thinking}, "thinking") or types != [] do
      %{
        supported: true,
        types: types,
        default_type: default_thinking_type(types),
        disable_supported: Enum.any?(types, &(&1 in ["disabled", "between_tools"])),
        raw_output_supported: supported?(thinking, "raw_output"),
        summary_supported: supported?(thinking, "summary"),
        encrypted_supported: supported?(thinking, "encrypted")
      }
    end
  end

  defp thinking_capability(_thinking), do: nil

  defp context_management_capability(context_management) when is_map(context_management) do
    features =
      context_management
      |> supported_child_names([])
      |> Enum.map(&strip_feature_date_suffix/1)
      |> Enum.uniq()

    %{supported: true, features: features}
  end

  defp context_management_capability(_context_management), do: %{supported: true}

  defp supported_child_names(children, preferred_order) when is_map(children) do
    supported =
      children
      |> Enum.reject(fn {key, _value} -> key == "supported" end)
      |> Enum.filter(fn {_key, value} -> match?(%{"supported" => true}, value) end)
      |> Enum.map(fn {key, _value} -> key end)

    ordered = Enum.filter(preferred_order, &(&1 in supported))
    extras = supported |> Enum.reject(&(&1 in ordered)) |> Enum.sort()

    ordered ++ extras
  end

  defp supported_child_names(_children, _preferred_order), do: []

  defp default_thinking_type(types) do
    cond do
      "adaptive" in types -> "adaptive"
      types != [] -> hd(types)
      true -> nil
    end
  end

  defp strip_feature_date_suffix(feature), do: String.replace(feature, ~r/_\d{8}$/, "")

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp fetch_all_pages(url, req_opts, limit, acc) do
    params = [limit: limit]

    params =
      case acc do
        [] -> params
        [%{"id" => last_id} | _] -> [{:after_id, last_id} | params]
      end

    req_opts = Keyword.put(req_opts, :params, params)

    case Remote.request_json(url, req_opts) do
      {:ok, body} when is_map(body) ->
        data = Map.get(body, "data", [])
        has_more = Map.get(body, "has_more", false)
        new_acc = acc ++ data

        if has_more and not Enum.empty?(data) do
          fetch_all_pages(url, req_opts, limit, new_acc)
        else
          {:ok, new_acc}
        end

      {:ok, _body} ->
        {:error, :invalid_shape}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_api_key(opts) do
    Map.get(opts, :api_key) || System.get_env("ANTHROPIC_API_KEY")
  end

  defp get_cache_dir do
    Application.get_env(:llm_db, :anthropic_cache_dir, @default_cache_dir)
  end

  defp build_headers(api_key, opts) do
    version = Map.get(opts, :anthropic_version, @default_version)
    headers = [{"x-api-key", api_key}, {"anthropic-version", version}]

    case Map.get(opts, :beta) do
      nil ->
        headers

      beta when is_list(beta) ->
        beta_value = Enum.join(beta, ",")
        [{"anthropic-beta", beta_value} | headers]

      beta when is_binary(beta) ->
        [{"anthropic-beta", beta} | headers]
    end
  end
end
