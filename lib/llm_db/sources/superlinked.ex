defmodule LLMDB.Sources.Superlinked do
  @moduledoc """
  Cached source for the Superlinked Inference Engine model catalog.

  `pull/1` requests `GET https://api.superlinked.com/v1/models` with a bearer
  token. Set `SIE_API_KEY` or `SUPERLINKED_API_KEY`, or pass `:api_key`.
  Tests can pass `:req_opts`, `:cache_dir`, and `:url`.

  `load/1` reads the cache without a network request or an API key. The source
  keeps models from an earlier successful pull when an account-specific reply
  omits them.

  Token-output models use the OpenAI-compatible Chat Completions contract.
  Dense-output models use the OpenAI-compatible Embeddings contract. Score
  output records rerank capability, but stays catalog-only unless the model also
  has an executable chat or dense embedding contract. Native sparse,
  multivector, JSON extraction, and OCR operations are catalog metadata only.
  """

  @behaviour LLMDB.Source

  alias LLMDB.Sources.Remote

  @default_url "https://api.superlinked.com/v1/models"
  @default_cache_dir "priv/llm_db/remote"
  @base_url "https://api.superlinked.com/v1"
  @docs_url "https://superlinked.com/docs/integrations"
  @environment_variables ["SIE_API_KEY", "SUPERLINKED_API_KEY"]
  @model_fields ~w(name inputs outputs dims max_sequence_length revision description release_date profiles capabilities routing aliases)
  @transient_fields ~w(loaded state last_error pending_generation)
  @modalities %{
    "text" => :text,
    "image" => :image,
    "audio" => :audio,
    "video" => :video,
    "document" => :document,
    "pdf" => :pdf
  }
  @chat_contract %{
    supported: true,
    family: "openai_chat_compatible",
    wire_protocol: "openai_chat",
    path: "/chat/completions"
  }
  @embedding_contract %{
    supported: true,
    family: "openai_embeddings",
    wire_protocol: "openai_embeddings",
    path: "/embeddings"
  }

  @impl true
  def pull(opts) do
    case api_key(opts) do
      key when is_binary(key) and key != "" -> pull_authenticated(opts, key)
      _missing -> {:error, :no_api_key}
    end
  end

  defp pull_authenticated(opts, key) do
    url = url(opts)
    req_opts = Map.get(opts, :req_opts, [])

    headers =
      req_opts
      |> Keyword.get(:headers, [])
      |> Enum.reject(fn {name, _value} -> String.downcase(to_string(name)) == "authorization" end)

    req_opts = Keyword.put(req_opts, :headers, [{"authorization", "Bearer " <> key} | headers])

    case Remote.request_json(url, req_opts) do
      {:ok, response} ->
        with :ok <- validate_response(response) do
          Remote.store(url, merge_catalog_cache(url, response, opts), cache_opts(opts))
        end

      {:error, {:http_status, status}} ->
        {:error, {:http_status, status}}

      {:error, {:json_error, _reason}} ->
        {:error, :invalid_response}

      {:error, _reason} ->
        {:error, :request_failed}
    end
  end

  @impl true
  def load(opts) do
    with {:ok, response} <- Remote.load(url(opts), cache_opts(opts)),
         :ok <- validate_response(response) do
      {:ok, transform(response)}
    end
  end

  @doc "Transforms the Superlinked catalog into canonical LLMDB data."
  def transform(%{"models" => models}) when is_list(models) do
    models =
      models
      |> Enum.filter(&valid_model?/1)
      |> Enum.map(&transform_model/1)
      |> Enum.sort_by(& &1.id)

    %{
      "superlinked" => %{
        id: :superlinked,
        name: "Superlinked SIE",
        base_url: @base_url,
        doc: @docs_url,
        env: @environment_variables,
        catalog_only: false,
        runtime: %{
          base_url: @base_url,
          doc_url: @docs_url,
          auth: %{type: "bearer", env: @environment_variables},
          execution: %{
            text: "openai_chat_compatible",
            embed: "openai_embeddings"
          }
        },
        models: models
      }
    }
  end

  def transform(_response), do: transform(%{"models" => []})

  defp transform_model(source) do
    id = source["name"]
    inputs = strings(source["inputs"])
    outputs = strings(source["outputs"])
    source_capabilities = map(source["capabilities"])
    grammar = strings(source_capabilities["grammar"])
    chat? = "tokens" in outputs
    dense? = "dense" in outputs
    rerank? = "score" in outputs
    streaming? = chat? and source_capabilities["streaming"] == true
    tools? = chat? and source_capabilities["tools"] == true
    json_schema? = chat? and "json_schema" in grammar
    dimensions = positive_integer(get_in(source, ["dims", "dense"]))
    execution = execution(chat?, dense?, json_schema? or tools?)

    %{
      id: id,
      provider: :superlinked,
      name: id,
      doc_url: @docs_url,
      release_date: nonempty_string(source["release_date"]),
      limits: limits(source),
      modalities: modalities(inputs, outputs),
      capabilities: %{
        chat: chat?,
        embeddings: embeddings(dense?, dimensions),
        rerank: rerank?,
        tools: %{enabled: tools?, streaming: tools? and streaming?},
        json: %{native: json_schema?, schema: json_schema?, strict: json_schema?},
        streaming: %{text: streaming?, tool_calls: tools? and streaming?}
      },
      execution: empty_to_nil(execution),
      catalog_only: map_size(execution) == 0,
      aliases: strings(source["aliases"]),
      extra: extra(source, inputs, outputs)
    }
    |> compact()
  end

  defp execution(chat?, dense?, object?) do
    %{}
    |> maybe_put(:text, @chat_contract, chat?)
    |> maybe_put(:object, @chat_contract, chat? and object?)
    |> maybe_put(:embed, @embedding_contract, dense?)
  end

  defp embeddings(false, _dimensions), do: false
  defp embeddings(true, nil), do: true

  defp embeddings(true, dimensions) do
    %{
      min_dimensions: dimensions,
      max_dimensions: dimensions,
      default_dimensions: dimensions
    }
  end

  defp limits(source) do
    case positive_integer(source["max_sequence_length"]) do
      nil -> nil
      context -> %{context: context}
    end
  end

  defp modalities(inputs, outputs) do
    input = inputs |> Enum.map(&Map.get(@modalities, &1)) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    output =
      []
      |> maybe_append(:text, Enum.any?(outputs, &(&1 in ["tokens", "json"])))
      |> maybe_append(:embedding, Enum.any?(outputs, &(&1 in ["dense", "sparse", "multivector"])))
      |> maybe_append(:decisions, "score" in outputs)

    %{}
    |> put_nonempty(:input, input)
    |> put_nonempty(:output, output)
    |> empty_to_nil()
  end

  defp extra(source, inputs, outputs) do
    %{
      source_url: @default_url,
      inputs: inputs,
      outputs: outputs,
      dimensions: map(source["dims"]),
      revision: nonempty_string(source["revision"]),
      description: nonempty_string(source["description"]),
      profiles: list(source["profiles"]),
      routing: map(source["routing"])
    }
    |> compact()
  end

  defp validate_response(%{"models" => models}) when is_list(models) do
    if Enum.all?(models, &valid_model?/1), do: :ok, else: {:error, :invalid_response}
  end

  defp validate_response(_response), do: {:error, :invalid_response}

  defp valid_model?(%{"name" => name, "inputs" => inputs, "outputs" => outputs}) do
    nonempty_string(name) != nil and string_list?(inputs) and string_list?(outputs)
  end

  defp valid_model?(_model), do: false

  defp merge_catalog_cache(url, response, opts) do
    previous =
      case Remote.load(url, cache_opts(opts)) do
        {:ok, cached} -> if validate_response(cached) == :ok, do: cached["models"], else: []
        {:error, _reason} -> []
      end

    models =
      (previous ++ response["models"])
      |> Map.new(fn model -> {model["name"], stable_model(model)} end)
      |> Map.values()
      |> Enum.sort_by(& &1["name"])

    data =
      Enum.map(models, fn model ->
        %{"id" => model["name"], "object" => "model", "created" => 0, "owned_by" => "sie"}
      end)

    %{"object" => "list", "data" => data, "models" => models}
  end

  defp stable_model(model) do
    model
    |> Map.take(@model_fields)
    |> Map.drop(@transient_fields)
  end

  defp api_key(opts) do
    Map.get(opts, :api_key) ||
      Enum.find_value(@environment_variables, fn variable ->
        case System.get_env(variable) do
          value when is_binary(value) and value != "" -> value
          _missing -> nil
        end
      end)
  end

  defp cache_opts(opts) do
    [
      cache_dir:
        Map.get(opts, :cache_dir) ||
          Application.get_env(:llm_db, :superlinked_cache_dir, @default_cache_dir),
      cache_key: "superlinked"
    ]
  end

  defp url(opts), do: Map.get(opts, :url, @default_url)

  defp strings(values) when is_list(values) do
    values
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp strings(_values), do: []
  defp string_list?(values), do: is_list(values) and Enum.all?(values, &is_binary/1)
  defp list(value) when is_list(value), do: value
  defp list(_value), do: []
  defp map(value) when is_map(value), do: value
  defp map(_value), do: %{}
  defp nonempty_string(value) when is_binary(value) and value != "", do: value
  defp nonempty_string(_value), do: nil
  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil
  defp maybe_put(map, key, value, true), do: Map.put(map, key, value)
  defp maybe_put(map, _key, _value, false), do: map
  defp maybe_append(list, value, true), do: list ++ [value]
  defp maybe_append(list, _value, false), do: list
  defp put_nonempty(map, _key, []), do: map
  defp put_nonempty(map, key, value), do: Map.put(map, key, value)
  defp compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
  defp empty_to_nil(map) when map_size(map) == 0, do: nil
  defp empty_to_nil(map), do: map
end
