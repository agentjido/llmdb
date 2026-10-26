defmodule LLMDB.Sources.InferenceNet do
  @moduledoc """
  Public Inference.net model catalog source.

  `pull/1` fetches `GET https://api.inference.net/v1/models` without an API
  key and stores the response in the remote cache. `load/1` reads only that
  cache and transforms the public fields into canonical LLMDB records.

  Inference.net uses an OpenAI-compatible Chat Completions API. The catalog
  publishes exact model IDs, token limits, reasoning effort levels,
  modalities, supported endpoints, prices, and privileged-access flags.

  Sources:

  - https://docs.inference.net/api/api-quickstart
  - https://docs.inference.net/api/coding-agents
  - https://docs.inference.net/api/reasoning
  - https://docs.inference.net/api/function-calling
  - https://docs.inference.net/api/structured-outputs

  Options: `:url`, `:cache_dir`, `:req_opts`, and an optional `:request` test
  hook. The default cache directory is configured by
  `:inference_net_cache_dir` and falls back to `priv/llm_db/remote`.
  """

  @behaviour LLMDB.Source

  alias LLMDB.Sources.Remote

  @default_url "https://api.inference.net/v1/models"
  @default_cache_dir "priv/llm_db/remote"
  @base_url "https://api.inference.net/v1"
  @docs_url "https://docs.inference.net/api/api-quickstart"
  @models_url "https://inference.net/models"
  @tool_disabled_models ["llama-3.2-1b-instruct", "llama-3.2-3b-instruct"]
  @obsolete_models_dev_models [
    "google/gemma-3",
    "meta/llama-3.1-8b-instruct",
    "meta/llama-3.2-11b-vision-instruct",
    "meta/llama-3.2-1b-instruct",
    "meta/llama-3.2-3b-instruct",
    "mistral/mistral-nemo-12b-instruct",
    "osmosis/osmosis-structure-0.6b",
    "qwen/qwen-2.5-7b-vision-instruct",
    "qwen/qwen3-embedding-4b"
  ]
  @modalities %{
    "text" => :text,
    "image" => :image,
    "audio" => :audio,
    "video" => :video,
    "code" => :code,
    "document" => :document,
    "embedding" => :embedding,
    "pdf" => :pdf
  }
  @chat_contract %{
    supported: true,
    family: "openai_chat_compatible",
    wire_protocol: "openai_chat",
    path: "/chat/completions"
  }

  @impl true
  def pull(opts) do
    Remote.pull(url(opts),
      cache_dir: cache_dir(opts),
      cache_key: "inference-net",
      req_opts: Map.get(opts, :req_opts, []),
      request: Map.get(opts, :request, &Req.get/2)
    )
  end

  @impl true
  def load(opts) do
    case Remote.load(url(opts), cache_dir: cache_dir(opts), cache_key: "inference-net") do
      {:ok, %{"data" => models} = content} when is_list(models) -> {:ok, transform(content)}
      {:ok, _content} -> {:error, :invalid_catalog}
      {:error, _reason} = error -> error
    end
  end

  @doc "Transforms the public catalog into canonical LLMDB data."
  def transform(content) do
    models =
      case content do
        %{"data" => models} when is_list(models) ->
          models
          |> Enum.filter(&valid_model?/1)
          |> Enum.map(&transform_model/1)

        _other ->
          []
      end

    %{
      "inference" => %{
        id: :inference,
        name: "Inference.net",
        base_url: @base_url,
        doc: @docs_url,
        env: ["INFERENCE_API_KEY"],
        exclude_models: @obsolete_models_dev_models,
        catalog_only: false,
        runtime: %{
          base_url: @base_url,
          doc_url: @docs_url,
          auth: %{type: "bearer", env: ["INFERENCE_API_KEY"]},
          execution: %{
            text: "openai_chat_compatible",
            object: "openai_chat_compatible"
          }
        },
        models: models
      }
    }
  end

  defp transform_model(source) do
    id = source["id"]
    endpoints = strings(source["supported_endpoints"])
    efforts = strings(source["reasoning_efforts"])
    chat? = "chat" in endpoints
    tools? = chat? and tools_supported?(id)

    %{
      id: id,
      provider: :inference,
      name: id,
      doc_url: @models_url,
      catalog_only: not chat?,
      limits: limits(source),
      cost: cost(source["pricing"]),
      modalities: modalities(source),
      capabilities: capabilities(chat?, tools?, efforts),
      execution: execution(chat?),
      tags: tags(source),
      extra: extra(source, endpoints, efforts)
    }
    |> compact()
  end

  defp capabilities(chat?, tools?, efforts) do
    %{
      chat: chat?,
      embeddings: false,
      reasoning: reasoning(efforts),
      tools: %{
        enabled: tools?,
        streaming: tools?,
        strict: tools?,
        parallel: false,
        forced_choice: false
      },
      json: %{native: chat?, schema: chat?, strict: chat?},
      streaming: %{text: chat?, tool_calls: tools?}
    }
  end

  defp reasoning([]), do: %{enabled: false}

  defp reasoning(efforts) do
    %{enabled: true, effort: %{supported: true, values: efforts}}
  end

  defp execution(true), do: %{text: @chat_contract, object: @chat_contract}
  defp execution(false), do: nil

  defp tools_supported?("inference-net/schematron-" <> _rest), do: false
  defp tools_supported?(id), do: id not in @tool_disabled_models

  defp limits(source) do
    %{}
    |> put_positive_integer(:context, source["context_length"])
    |> put_positive_integer(:output, source["max_completion_tokens"])
    |> empty_to_nil()
  end

  defp cost(pricing) when is_map(pricing) do
    %{}
    |> put_price(:input, pricing["prompt"])
    |> put_price(:output, pricing["completion"])
    |> put_price(:cache_read, pricing["input_cache_read"])
    |> put_price(:cache_write, pricing["input_cache_write"])
    |> empty_to_nil()
  end

  defp cost(_pricing), do: nil

  defp modalities(source) do
    input = known_modalities(source["input_modalities"])
    output = known_modalities(source["output_modalities"])

    %{}
    |> put(:input, input)
    |> put(:output, output)
    |> empty_to_nil()
  end

  defp known_modalities(values) when is_list(values) do
    values
    |> Enum.map(&Map.get(@modalities, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp known_modalities(_values), do: nil

  defp tags(%{"requires_approved_access" => true}), do: ["privileged"]
  defp tags(_source), do: nil

  defp extra(source, endpoints, efforts) do
    %{
      source_url: @default_url,
      object: source["object"],
      owned_by: source["owned_by"],
      supported_endpoints: endpoints,
      reasoning_efforts: efforts,
      requires_approved_access: source["requires_approved_access"] == true
    }
  end

  defp valid_model?(%{"id" => id}) when is_binary(id), do: String.trim(id) != ""
  defp valid_model?(_model), do: false

  defp strings(values) when is_list(values) do
    values
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp strings(_values), do: []

  defp put_positive_integer(map, key, value) when is_integer(value) and value > 0,
    do: Map.put(map, key, value)

  defp put_positive_integer(map, _key, _value), do: map

  defp put_price(map, key, value) do
    case token_price(value) do
      nil -> map
      price -> Map.put(map, key, price)
    end
  end

  defp token_price(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} when number >= 0 -> token_price(number)
      _other -> nil
    end
  end

  defp token_price(value) when is_number(value) and value >= 0 do
    Float.round(value * 1_000_000.0, 9)
  rescue
    ArithmeticError -> nil
  end

  defp token_price(_value), do: nil

  defp put(map, _key, nil), do: map
  defp put(map, _key, []), do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
  defp empty_to_nil(map) when map_size(map) == 0, do: nil
  defp empty_to_nil(map), do: map

  defp url(opts), do: Map.get(opts, :url, @default_url)

  defp cache_dir(opts) do
    Map.get(
      opts,
      :cache_dir,
      Application.get_env(:llm_db, :inference_net_cache_dir, @default_cache_dir)
    )
  end
end
