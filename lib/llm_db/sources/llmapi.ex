defmodule LLMDB.Sources.LLMAPI do
  @moduledoc """
  Public LLM API catalog source (https://api.llmapi.ai/v1/models).

  `pull/1` explicitly fetches the public catalog without credentials. `load/1`
  only reads its local cache. Application filters are applied by the engine,
  never by this source.

  The public catalog mixes Chat, Responses-only, and media models. Every exact
  ID is retained, but Chat execution is declared only when all advertised
  fallback routes support it. Capabilities are intersected across those routes.
  Object generation uses ReqLLM's shared tool-based object adapter, not native
  JSON Schema output. These contracts describe published metadata; live API
  compatibility remains to be verified.

  Top-level chat prices are USD per token, unlike upstream route prices. The
  public Models page multiplies top-level rates by 1,000,000 for its display.
  No output-token limits or strict/streamed-tool guarantees are published.

  Sources:
  - https://docs.llmapi.ai/api/v1/models
  - https://docs.llmapi.ai/api/v1/chat/completions
  - https://docs.llmapi.ai/models

  Options: `:url`, `:cache_dir`, `:req_opts`, and an optional `:request` test hook.
  The default cache directory is configured by `:llmapi_cache_dir` and falls
  back to `priv/llm_db/remote`.
  """

  @behaviour LLMDB.Source

  alias LLMDB.Sources.Remote

  @default_url "https://api.llmapi.ai/v1/models"
  @default_cache_dir "priv/llm_db/remote"
  @docs_url "https://docs.llmapi.ai/api/v1/models"
  @mapped_prices ~w(prompt completion input_cache_read input_cache_write)
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
      cache_key: "llmapi",
      req_opts: Map.get(opts, :req_opts, []),
      request: Map.get(opts, :request, &Req.get/2)
    )
  end

  @impl true
  def load(opts) do
    case Remote.load(url(opts), cache_dir: cache_dir(opts), cache_key: "llmapi") do
      {:ok, %{"data" => models} = content} when is_list(models) -> {:ok, transform(content)}
      {:ok, _content} -> {:error, :invalid_catalog}
      {:error, _reason} = error -> error
    end
  end

  @doc "Transforms the public catalog into canonical data without filtering model IDs."
  def transform(content) do
    models =
      case content do
        %{"data" => models} when is_list(models) -> models
        _other -> []
      end

    %{
      "llmapi" => %{
        id: :llmapi,
        name: "LLM API",
        models: models |> Enum.filter(&valid_model?/1) |> Enum.map(&transform_model/1)
      }
    }
  end

  defp transform_model(source) do
    routes = list(source["providers"])
    architecture = map(source["architecture"])
    params = list(source["supported_parameters"])
    lifecycle = lifecycle(source)
    executable? = executable_chat?(source, routes, architecture) and not lifecycle.retired

    model =
      %{
        id: source["id"],
        provider: :llmapi,
        doc_url: @docs_url,
        catalog_only: not executable?,
        deprecated: lifecycle.deprecated,
        retired: lifecycle.retired,
        extra: extra(source, routes)
      }
      |> put(:name, string(source["name"]))
      |> put(:family, string(source["family"]))
      |> put(:release_date, iso_date(source["released_at"]))
      |> put(:aliases, aliases(source["aliases"]))
      |> put(:lifecycle, lifecycle.metadata)
      |> put(:cost, cost(source))

    if executable? do
      capabilities = capabilities(routes, params)
      limits = context_limits(source, routes)
      modalities = chat_modalities(architecture, routes)

      extra =
        model.extra
        |> put_if_different(:reported_context_length, source["context_length"], limits[:context])
        |> put_if_different(
          :reported_modalities,
          Map.take(architecture, ~w(input_modalities output_modalities)),
          string_modalities(modalities)
        )

      execution =
        %{text: @chat_contract}
        |> maybe_object(capabilities, params)

      model
      |> Map.put(:execution, execution)
      |> Map.put(:capabilities, capabilities)
      |> Map.put(:modalities, modalities)
      |> Map.put(:extra, extra)
      |> put(:limits, empty_to_nil(limits))
    else
      extra =
        model.extra
        |> put(:architecture, source["architecture"])
        |> put(:pricing, source["pricing"])
        |> put(:context_length, source["context_length"])

      if documented_chat?(source, routes, architecture) do
        limits = context_limits(source, routes)
        modalities = chat_modalities(architecture, routes)

        extra =
          extra
          |> put_if_different(
            :reported_context_length,
            source["context_length"],
            limits[:context]
          )
          |> put_if_different(
            :reported_modalities,
            Map.take(architecture, ~w(input_modalities output_modalities)),
            string_modalities(modalities)
          )

        model
        |> Map.put(:capabilities, capabilities(routes, params))
        |> Map.put(:modalities, modalities)
        |> put(:limits, empty_to_nil(limits))
        |> Map.put(:extra, extra)
      else
        model
        |> Map.put(:capabilities, descriptive_capabilities(source))
        |> put(:modalities, descriptive_modalities(architecture))
        |> Map.put(:extra, extra)
      end
    end
  end

  defp descriptive_capabilities(source) do
    # Explicit values prevent canonical chat/streaming defaults from turning
    # media and unverified entries into apparent text-generation candidates.
    %{
      chat: source["kind"] == "chat",
      embeddings: source["kind"] == "embedding",
      reasoning: %{enabled: false},
      tools: %{enabled: false, streaming: false, strict: false, parallel: false},
      json: %{native: false, schema: false, strict: false},
      streaming: %{text: false, tool_calls: false}
    }
  end

  defp descriptive_modalities(architecture) do
    %{}
    |> put(:input, known_modalities(architecture["input_modalities"]))
    |> put(:output, known_modalities(architecture["output_modalities"]))
    |> empty_to_nil()
  end

  defp known_modalities(values) when is_list(values) do
    values
    |> Enum.map(&Map.get(@modalities, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp known_modalities(_values), do: nil

  defp executable_chat?(source, routes, architecture) do
    documented_chat?(source, routes, architecture) and
      Enum.all?(routes, &(&1["responsesOnly"] in [nil, false]))
  end

  defp documented_chat?(source, routes, architecture) do
    source["kind"] == "chat" and routes != [] and
      "text" in list(architecture["input_modalities"]) and
      "text" in list(architecture["output_modalities"]) and
      Enum.all?(routes, fn route ->
        is_map(route) and not is_nil(string(route["providerId"])) and
          not is_nil(string(route["modelName"])) and route["responsesOnly"] in [nil, false, true]
      end)
  end

  defp capabilities(routes, params) do
    tools? = all_routes?(routes, "tools") and "tools" in params

    %{
      chat: true,
      reasoning: %{enabled: all_routes?(routes, "reasoning")},
      tools: %{
        enabled: tools?,
        streaming: false,
        strict: false,
        parallel: tools? and all_routes?(routes, "parallelToolCalls"),
        forced_choice: false
      },
      json: %{
        native: all_routes?(routes, "json_output") and "response_format" in params,
        schema: all_routes?(routes, "structured_outputs") and "response_format" in params,
        strict: false
      },
      streaming: %{text: all_routes?(routes, "streaming"), tool_calls: false}
    }
  end

  defp maybe_object(execution, %{tools: %{enabled: true}}, params) do
    # The shared object adapter adds max_tokens even without an output limit.
    # A tool-capable route alone does not establish support for that payload.
    if Enum.all?(~w(tool_choice max_tokens), &(&1 in params)),
      do: Map.put(execution, :object, @chat_contract),
      else: execution
  end

  defp maybe_object(execution, _capabilities, _params), do: execution

  defp all_routes?(routes, field), do: Enum.all?(routes, &(Map.get(&1, field) == true))

  defp context_limits(source, routes) do
    route_contexts = Enum.map(routes, &Map.get(&1, "contextSize"))

    if Enum.all?(route_contexts, &(is_integer(&1) and &1 > 0)) do
      contexts =
        [source["context_length"] | route_contexts]
        |> Enum.filter(&(is_integer(&1) and &1 > 0))

      %{context: Enum.min(contexts)}
    else
      %{}
    end
  end

  defp chat_modalities(architecture, routes) do
    input = list(architecture["input_modalities"])

    modalities =
      [
        text: true,
        image: all_routes?(routes, "vision"),
        audio: all_routes?(routes, "audio_input"),
        video: all_routes?(routes, "video_input")
      ]
      |> Enum.filter(fn {modality, supported?} ->
        supported? and Atom.to_string(modality) in input
      end)
      |> Enum.map(&elem(&1, 0))

    %{input: modalities, output: [:text]}
  end

  defp string_modalities(modalities) do
    %{
      "input_modalities" => Enum.map(modalities.input, &Atom.to_string/1),
      "output_modalities" => Enum.map(modalities.output, &Atom.to_string/1)
    }
  end

  defp cost(%{"kind" => "chat"} = source) do
    pricing = map(source["pricing"])

    %{}
    |> put(:input, token_price(pricing["prompt"]))
    |> put(:output, token_price(pricing["completion"]))
    |> put(:cache_read, token_price(pricing["input_cache_read"]))
    |> put(:cache_write, token_price(pricing["input_cache_write"]))
    |> empty_to_nil()
  end

  defp cost(_source), do: nil

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

  defp extra(source, routes) do
    mappings =
      routes
      |> Enum.filter(&is_map/1)
      |> Enum.map(&Map.take(&1, ~w(providerId modelName responsesOnly)))

    %{
      source_url: @default_url,
      upstream_models: mappings
    }
    |> put(:kind, source["kind"])
    |> put(:free, source["free"])
    |> put(:supported_parameters, source["supported_parameters"])
    |> put(:reasoning_levels, source["reasoning_levels"])
    |> put(:unmapped_pricing, unmapped_pricing(source))
    |> put(:published_lifecycle, empty_to_nil(Map.take(source, ~w(deprecated_at deactivated_at))))
  end

  defp unmapped_pricing(%{"kind" => "chat"} = source) do
    pricing = map(source["pricing"])

    # Invalid/blank values remain evidence rather than becoming zero-cost rates.
    Enum.reduce(@mapped_prices, Map.drop(pricing, @mapped_prices), fn key, unmapped ->
      if not is_nil(pricing[key]) and is_nil(token_price(pricing[key])),
        do: Map.put(unmapped, key, pricing[key]),
        else: unmapped
    end)
    |> empty_to_nil()
  end

  defp unmapped_pricing(_source), do: nil

  defp lifecycle(source) do
    deprecated_at = lifecycle_date(source["deprecated_at"])
    retires_at = lifecycle_date(source["deactivated_at"])
    deprecated? = effective?(deprecated_at)
    retired? = effective?(retires_at)

    metadata =
      if deprecated_at || retires_at do
        %{
          status:
            cond do
              retired? -> "retired"
              deprecated? -> "deprecated"
              true -> "active"
            end
        }
        |> put(:deprecated_at, if(deprecated_at, do: source["deprecated_at"]))
        |> put(:retires_at, if(retires_at, do: source["deactivated_at"]))
      end

    %{deprecated: deprecated?, retired: retired?, metadata: metadata}
  end

  defp effective?(nil), do: false

  defp effective?(%DateTime{} = datetime),
    do: DateTime.compare(datetime, DateTime.utc_now()) != :gt

  defp effective?(date), do: Date.compare(date, Date.utc_today()) != :gt

  defp lifecycle_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} ->
        date

      _other ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> datetime
          _other -> nil
        end
    end
  end

  defp lifecycle_date(_value), do: nil

  defp iso_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, _date} -> value
      _other -> nil
    end
  end

  defp iso_date(_value), do: nil

  defp aliases(value) when is_list(value), do: value |> Enum.filter(&string/1) |> Enum.uniq()
  defp aliases(_value), do: nil
  defp valid_model?(%{"id" => id}), do: not is_nil(string(id))
  defp valid_model?(_value), do: false
  defp string(value) when is_binary(value), do: if(String.trim(value) != "", do: value)
  defp string(_value), do: nil
  defp list(value) when is_list(value), do: value
  defp list(_value), do: []
  defp map(value) when is_map(value), do: value
  defp map(_value), do: %{}
  defp empty_to_nil(map) when map_size(map) == 0, do: nil
  defp empty_to_nil(map), do: map
  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)
  defp put_if_different(map, _key, value, value), do: map
  defp put_if_different(map, key, value, _canonical), do: put(map, key, value)
  defp url(opts), do: Map.get(opts, :url, @default_url)

  defp cache_dir(opts) do
    Map.get(opts, :cache_dir) ||
      Application.get_env(:llm_db, :llmapi_cache_dir, @default_cache_dir)
  end
end
