defmodule LLMDB.ExecutionContract do
  @moduledoc """
  Deterministic runtime-contract enrichment for packaged provider and model data.

  This module upgrades descriptive catalog data into executable metadata where we
  have a stable contract for doing so. Providers and models we cannot execute
  safely are marked `catalog_only: true` so downstream consumers can distinguish
  between descriptive and executable entries without ad hoc heuristics.

  Execution metadata follows one precedence rule: explicit model operation
  entries override provider/runtime-derived entries, which override capability
  and modality inference. Validation uses the same inference functions, so it
  cannot require an operation that enrichment would not derive.
  """

  alias LLMDB.{Merge, Model, Provider}

  @google_generation_methods MapSet.new([
                               "generateAnswer",
                               "generateContent",
                               "batchGenerateContent"
                             ])
  @cohere_embedding_methods MapSet.new(["embed", "embedText", "embedTexts"])
  @cohere_rerank_methods MapSet.new(["rerank"])

  @family_wire_protocol %{
    "openai_chat_compatible" => "openai_chat",
    "openai_responses_compatible" => "openai_responses",
    "openai_embeddings" => "openai_embeddings",
    "openai_images" => "openai_images",
    "minimax_images" => "minimax_images",
    "openai_transcription" => "openai_transcription",
    "openai_speech" => "openai_speech",
    "openai_realtime" => "openai_realtime",
    "anthropic_messages" => "anthropic_messages",
    "google_generate_content" => "google_generate_content",
    "cohere_chat" => "cohere_chat",
    "elevenlabs_speech" => "elevenlabs_speech",
    "elevenlabs_transcription" => "elevenlabs_transcription"
  }

  @family_paths %{
    "openai_chat_compatible" => "/chat/completions",
    "openai_responses_compatible" => "/responses",
    "openai_embeddings" => "/embeddings",
    "openai_images" => "/images/generations",
    "minimax_images" => "/image_generation",
    "openai_transcription" => "/audio/transcriptions",
    "openai_speech" => "/audio/speech",
    "openai_realtime" => "/realtime",
    "anthropic_messages" => "/v1/messages",
    "google_generate_content" => "/models/{provider_model_id}:generateContent",
    "cohere_chat" => "/v2/chat",
    "elevenlabs_speech" => "/v1/text-to-speech/{provider_model_id}",
    "elevenlabs_transcription" => "/v1/speech-to-text"
  }

  @execution_operations [:text, :object, :embed, :image, :transcription, :speech, :realtime]
  @execution_families Map.keys(@family_wire_protocol)

  @rerank_capabilities %{
    chat: false,
    embeddings: false,
    reasoning: %{enabled: false},
    rerank: true,
    tools: %{enabled: false, streaming: false, strict: false, parallel: false},
    json: %{native: false, schema: false, strict: false},
    streaming: %{text: false, tool_calls: false}
  }

  @spec enrich([Provider.t()], [Model.t()]) :: {[Provider.t()], [Model.t()]}
  def enrich(providers, models) when is_list(providers) and is_list(models) do
    {enriched_providers, enriched_models} = enrich_for_validation(providers, models)
    published_providers = Enum.map(enriched_providers, &publish_provider/1)

    {published_providers, enriched_models}
  end

  @doc false
  @spec enrich_for_validation([Provider.t()], [Model.t()]) :: {[Provider.t()], [Model.t()]}
  def enrich_for_validation(providers, models) when is_list(providers) and is_list(models) do
    enriched_providers = Enum.map(providers, &enrich_provider/1)
    provider_lookup = Map.new(enriched_providers, &{&1.id, &1})

    enriched_models =
      Enum.map(models, fn model ->
        enrich_model(model, Map.get(provider_lookup, model.provider))
      end)

    {enriched_providers, enriched_models}
  end

  @doc false
  @spec publish_provider(Provider.t()) :: Provider.t()
  def publish_provider(%Provider{runtime: runtime} = provider) when is_map(runtime) do
    %{provider | runtime: Map.delete(runtime, :execution)}
  end

  def publish_provider(provider), do: provider

  @spec enrich_provider(Provider.t()) :: Provider.t()
  def enrich_provider(%Provider{} = provider) do
    runtime = resolved_runtime(provider)

    catalog_only =
      provider.catalog_only or
        (is_nil(provider.runtime) and is_nil(runtime))

    provider
    |> Map.put(:runtime, runtime)
    |> Map.put(:catalog_only, catalog_only)
  end

  @spec enrich_model(Model.t(), Provider.t() | nil) :: Model.t()
  def enrich_model(%Model{} = model, provider) do
    execution =
      model
      |> derive_execution(provider)
      |> merge_execution(model.execution)
      |> normalize_execution()

    capabilities =
      merge_capabilities(model.capabilities, derive_capabilities(model))

    catalog_only =
      model.catalog_only or
        is_nil(provider) or
        Map.get(provider, :catalog_only) == true or
        (is_nil(model.execution) and not executable_execution?(execution))

    model
    |> Map.put(:execution, execution)
    |> Map.put(:capabilities, capabilities)
    |> Map.put(:catalog_only, catalog_only)
  end

  @doc false
  @spec operations() :: [atom()]
  def operations, do: @execution_operations

  @doc false
  @spec implied_operations(Model.t(), Provider.t() | nil) :: [atom()]
  def implied_operations(%Model{} = model, provider) do
    model
    |> derive_execution(provider)
    |> case do
      execution when is_map(execution) -> Map.keys(execution)
      _other -> []
    end
  end

  @doc false
  @spec valid_family?(term()) :: boolean()
  def valid_family?(family), do: family in @execution_families

  @doc false
  @spec executable?(map() | nil) :: boolean()
  def executable?(execution), do: executable_execution?(execution)

  defp resolved_runtime(%Provider{} = provider) do
    case provider.runtime do
      existing when is_map(existing) ->
        normalize_runtime(existing, provider)

      _other ->
        nil
    end
  end

  defp normalize_runtime(runtime, provider) do
    auth =
      runtime
      |> Map.get(:auth, %{})
      |> normalize_auth(provider)

    %{
      base_url: Map.get(runtime, :base_url) || provider.base_url,
      auth: auth,
      default_headers: Map.get(runtime, :default_headers, %{}),
      default_query: Map.get(runtime, :default_query, %{}),
      config_schema: Map.get(runtime, :config_schema) || provider.config_schema,
      doc_url: Map.get(runtime, :doc_url) || provider.doc,
      execution: Map.get(runtime, :execution)
    }
  end

  defp normalize_auth(auth, provider) do
    env =
      case Map.get(auth, :env) do
        env when is_list(env) and env != [] -> env
        _other -> provider.env || []
      end

    auth
    |> Map.put(:env, env)
    |> Map.put_new(:headers, [])
  end

  defp derive_execution(
         %Model{} = model,
         %Provider{catalog_only: false} = provider
       ) do
    []
    |> maybe_put_entry(:text, text_entry(model, provider))
    |> maybe_put_entry(:object, object_entry(model, provider))
    |> maybe_put_entry(:embed, media_entry(model, provider, :embed, &embedding_model?/1))
    |> maybe_put_entry(:image, media_entry(model, provider, :image, &image_generation_model?/1))
    |> maybe_put_entry(
      :transcription,
      media_entry(model, provider, :transcription, &dedicated_transcription_model?/1)
    )
    |> maybe_put_entry(:speech, media_entry(model, provider, :speech, &dedicated_speech_model?/1))
    |> maybe_put_entry(:realtime, realtime_entry(model, provider))
    |> Map.new()
    |> nil_if_empty()
  end

  defp derive_execution(_model, _provider), do: nil

  defp text_entry(model, provider) do
    if text_object_capable?(model, provider) do
      execution_entry(model, provider, text_object_family(model, provider, :text))
    end
  end

  defp object_entry(model, provider) do
    if object_capable?(model, provider) do
      execution_entry(model, provider, text_object_family(model, provider, :object))
    end
  end

  defp media_entry(model, provider, operation, classifier) do
    family = provider_family(provider, operation)

    if is_binary(family) and classifier.(model) do
      execution_entry(model, provider, family)
    end
  end

  defp realtime_entry(model, provider) do
    family = provider_family(provider, :realtime)

    if is_binary(family) and realtime_model?(model) do
      execution_entry(model, provider, family)
      |> Map.put(:transport, "websocket")
    end
  end

  defp text_object_capable?(model, provider) do
    family = text_object_family(model, provider, :text)
    is_binary(family)
  end

  defp object_capable?(model, provider) do
    family = text_object_family(model, provider, :object)

    is_binary(family) and
      (family != "anthropic_messages" or json_schema_capable?(model))
  end

  defp json_schema_capable?(%Model{capabilities: capabilities}) when is_map(capabilities) do
    case Map.get(capabilities, :json) do
      %{schema: true} -> true
      %{native: true} -> true
      %{strict: true} -> true
      _other -> false
    end
  end

  defp json_schema_capable?(_model), do: false

  defp text_object_family(model, provider, operation) do
    configured_family = provider_family(provider, operation)

    cond do
      protocol = text_object_protocol(model) ->
        protocol_family(protocol)

      configured_family == "google_generate_content" and google_text_object_model?(model) ->
        configured_family

      configured_family == "cohere_chat" and cohere_chat_model?(model) ->
        configured_family

      configured_family in ["google_generate_content", "cohere_chat"] ->
        nil

      is_binary(configured_family) and chat_generation_model?(model) ->
        configured_family

      true ->
        nil
    end
  end

  defp google_text_object_model?(model) do
    methods = supported_generation_methods(model)
    MapSet.disjoint?(@google_generation_methods, methods) == false
  end

  defp provider_family(%Provider{runtime: %{execution: execution}}, operation)
       when is_map(execution),
       do: Map.get(execution, operation)

  defp provider_family(_provider, _operation), do: nil

  defp cohere_chat_model?(model) do
    chat_generation_model?(model) and not cohere_embedding_or_rerank_model?(model)
  end

  defp cohere_embedding_or_rerank_model?(model) do
    methods = supported_generation_methods(model)

    MapSet.disjoint?(@cohere_embedding_methods, methods) == false or
      rerank_model?(model) or
      embedding_model?(model)
  end

  defp derive_capabilities(model) do
    if rerank_model?(model), do: @rerank_capabilities
  end

  defp merge_capabilities(nil, nil), do: nil
  defp merge_capabilities(nil, derived), do: derived
  defp merge_capabilities(existing, nil), do: existing

  defp merge_capabilities(existing, derived) when is_map(existing) and is_map(derived) do
    Merge.merge(existing, derived, :higher)
  end

  defp text_object_protocol(model) do
    protocol =
      case wire_protocol(model) do
        "openai_chat" -> "openai_chat"
        "openai_responses" -> "openai_responses"
        "anthropic_messages" -> "anthropic_messages"
        _other -> nil
      end

    if protocol in ["openai_chat", "openai_responses", "anthropic_messages"], do: protocol
  end

  defp protocol_family("openai_chat"), do: "openai_chat_compatible"
  defp protocol_family("openai_responses"), do: "openai_responses_compatible"
  defp protocol_family("anthropic_messages"), do: "anthropic_messages"
  defp protocol_family(_protocol), do: nil

  defp execution_entry(model, provider, family) when is_binary(family) do
    wire_protocol = Map.get(@family_wire_protocol, family)
    provider_model_id = provider_model_id_override(model)
    base_url = model_base_url_override(model, provider)

    %{
      supported: true,
      family: family,
      wire_protocol: wire_protocol,
      provider_model_id: provider_model_id,
      base_url: base_url,
      path: Map.get(@family_paths, family)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp provider_model_id_override(%Model{id: id, provider_model_id: provider_model_id})
       when is_binary(provider_model_id) and provider_model_id != id,
       do: provider_model_id

  defp provider_model_id_override(_model), do: nil

  defp model_base_url_override(%Model{base_url: base_url}, %Provider{} = provider)
       when is_binary(base_url) do
    provider_base_url = get_in(provider, [Access.key(:runtime), Access.key(:base_url)])

    if base_url != provider_base_url, do: base_url
  end

  defp model_base_url_override(_model, _provider), do: nil

  defp merge_execution(nil, existing), do: existing
  defp merge_execution(derived, nil), do: derived

  defp merge_execution(derived, existing) when is_map(derived) and is_map(existing) do
    Map.merge(derived, existing, fn _operation, derived_entry, existing_entry ->
      derived_entry
      |> align_family_defaults(existing_entry)
      |> Map.merge(existing_entry)
    end)
  end

  defp align_family_defaults(derived_entry, %{family: family}) when is_binary(family) do
    derived_entry
    |> Map.put(:family, family)
    |> Map.put(:wire_protocol, Map.get(@family_wire_protocol, family))
    |> Map.put(:path, Map.get(@family_paths, family))
  end

  defp align_family_defaults(derived_entry, _existing_entry), do: derived_entry

  defp normalize_execution(nil), do: nil

  defp normalize_execution(execution) when is_map(execution) do
    execution
    |> Enum.reject(fn {_operation, entry} -> is_nil(entry) end)
    |> Enum.map(fn {operation, entry} ->
      normalized_entry =
        entry
        |> Map.put_new(:supported, true)
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()

      {operation, normalized_entry}
    end)
    |> Map.new()
    |> nil_if_empty()
  end

  defp executable_execution?(nil), do: false

  defp executable_execution?(execution) when is_map(execution) do
    Enum.any?(execution, fn {_operation, entry} ->
      is_map(entry) and Map.get(entry, :supported) == true and is_binary(Map.get(entry, :family))
    end)
  end

  defp maybe_put_entry(entries, _operation, nil), do: entries
  defp maybe_put_entry(entries, operation, entry), do: [{operation, entry} | entries]

  defp nil_if_empty(map) when map in [%{}, []], do: nil
  defp nil_if_empty(map), do: map

  defp wire_protocol(%Model{extra: extra}) when is_map(extra) do
    wire = Map.get(extra, :wire) || Map.get(extra, "wire") || %{}

    protocol =
      cond do
        is_map(wire) ->
          Map.get(wire, :protocol) || Map.get(wire, "protocol")

        true ->
          nil
      end

    normalize_string(
      protocol || Map.get(extra, :wire_protocol) || Map.get(extra, "wire_protocol") ||
        Map.get(extra, :api) || Map.get(extra, "api")
    )
  end

  defp wire_protocol(_model), do: nil

  defp supported_generation_methods(%Model{extra: extra}) when is_map(extra) do
    extra
    |> then(fn map ->
      Map.get(map, :supported_generation_methods) ||
        Map.get(map, "supported_generation_methods") || []
    end)
    |> Enum.map(&to_string/1)
    |> MapSet.new()
  end

  defp supported_generation_methods(_model), do: MapSet.new()

  defp rerank_model?(model) do
    rerank_capability?(model) or
      rerank_type?(model) or
      rerank_generation_method?(model) or
      rerank_named_model?(model)
  end

  defp rerank_capability?(%Model{capabilities: %{rerank: true}}), do: true
  defp rerank_capability?(_model), do: false

  defp rerank_type?(%Model{extra: extra}) when is_map(extra) do
    normalize_string(Map.get(extra, :type) || Map.get(extra, "type")) == "rerank"
  end

  defp rerank_type?(_model), do: false

  defp rerank_generation_method?(model) do
    methods = supported_generation_methods(model)
    MapSet.disjoint?(@cohere_rerank_methods, methods) == false
  end

  defp rerank_named_model?(%Model{id: id, name: name}) do
    rerank_name?(id) or rerank_name?(name)
  end

  defp rerank_name?(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.contains?("rerank")
  end

  defp rerank_name?(_value), do: false

  defp chat_generation_model?(model) do
    cond do
      exclusive_media_model?(model) ->
        false

      chat_capability?(model) ->
        true

      text_input?(model) and text_output?(model) ->
        true

      no_capability_or_modality_metadata?(model) ->
        true

      true ->
        false
    end
  end

  defp chat_capability?(%Model{capabilities: %{chat: true}}), do: true
  defp chat_capability?(_model), do: false

  defp no_capability_or_modality_metadata?(%Model{capabilities: nil, modalities: nil}), do: true
  defp no_capability_or_modality_metadata?(_model), do: false

  defp text_input?(%Model{modalities: %{input: input}}) when is_list(input), do: :text in input
  defp text_input?(_model), do: false

  defp text_output?(%Model{} = model) do
    case model.modalities do
      %{output: output} when is_list(output) -> :text in output
      _other -> chat_capability?(model)
    end
  end

  defp embedding_model?(%Model{modalities: %{output: output}}) when is_list(output),
    do: :embedding in output or :embeddings in output

  defp embedding_model?(%Model{capabilities: capabilities}) when is_map(capabilities) do
    case Map.get(capabilities, :embeddings) do
      true -> true
      embeddings when is_map(embeddings) -> true
      _other -> false
    end
  end

  defp embedding_model?(%Model{extra: extra}) when is_map(extra) do
    normalize_string(Map.get(extra, :type) || Map.get(extra, "type")) == "embedding"
  end

  defp embedding_model?(_model), do: false

  defp image_generation_model?(%Model{modalities: %{output: output}}) when is_list(output),
    do: :image in output

  defp image_generation_model?(model) do
    wire_protocol(model) in ["images", "openai_images"]
  end

  defp transcription_model?(%Model{id: id} = model) do
    normalized_id = String.downcase(id)

    audio_transcription_shape?(model) or
      wire_protocol(model) in ["audio", "audio.transcriptions", "audio.translation"] or
      String.contains?(normalized_id, "transcribe") or
      String.contains?(normalized_id, "whisper")
  end

  defp speech_model?(%Model{id: id} = model) do
    normalized_id = String.downcase(id)

    text_to_audio_shape?(model) or
      wire_protocol(model) in ["tts", "audio.speech"] or
      String.starts_with?(normalized_id, "tts-") or
      String.contains?(normalized_id, "-tts")
  end

  defp realtime_model?(%Model{id: id} = model) do
    normalized_id = String.downcase(id)

    wire_protocol(model) in ["realtime", "openai_realtime"] or
      String.contains?(normalized_id, "realtime")
  end

  defp exclusive_media_model?(model) do
    embedding_model?(model) or image_generation_model?(model) or realtime_model?(model) or
      dedicated_transcription_model?(model) or dedicated_speech_model?(model)
  end

  defp dedicated_transcription_model?(model) do
    transcription_model?(model) and not chat_capability?(model) and not text_input?(model)
  end

  defp dedicated_speech_model?(model) do
    speech_model?(model) and not chat_capability?(model) and not text_output?(model)
  end

  defp audio_transcription_shape?(%Model{modalities: %{input: input, output: output}})
       when is_list(input) and is_list(output),
       do: :audio in input and :text in output

  defp audio_transcription_shape?(_model), do: false

  defp text_to_audio_shape?(%Model{modalities: %{input: input, output: output}})
       when is_list(input) and is_list(output),
       do: :text in input and :audio in output

  defp text_to_audio_shape?(_model), do: false

  defp normalize_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_string(value) when is_binary(value), do: value
  defp normalize_string(_value), do: nil
end
