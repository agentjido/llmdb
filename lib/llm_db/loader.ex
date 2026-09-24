defmodule LLMDB.Loader do
  @moduledoc """
  Handles loading and merging of packaged snapshots with runtime customization.

  Phase 2 of LLMDB: Load the packaged snapshot, apply custom overlays,
  compile filters, and build indexes for runtime queries.

  This module encapsulates all snapshot loading logic, keeping the main
  LLMDB module focused on the query API.
  """

  alias LLMDB.{
    Catalog,
    Engine,
    Merge,
    Model,
    Packaged,
    Pricing,
    Provider,
    Runtime,
    Snapshot,
    Validate
  }

  alias LLMDB.Generated.{ProviderRegistry, ValidModalities}
  alias LLMDB.Snapshot.ReleaseStore

  require Logger

  @known_snapshot_keys [
    :alias_of,
    :aliases,
    :applies_to,
    :applies_when,
    :audio,
    :auth,
    :base_url,
    :batch,
    :cache_read,
    :cache_write,
    :caching,
    :capabilities,
    :catalog_only,
    :charge_scope,
    :chat,
    :citations,
    :code_execution,
    :components,
    :config_schema,
    :context,
    :context_management,
    :cost,
    :currency,
    :default,
    :default_dimensions,
    :default_headers,
    :default_query,
    :default_type,
    :deprecated,
    :deprecated_at,
    :derives_from,
    :disable_supported,
    :doc,
    :doc_url,
    :effort,
    :embed,
    :embeddings,
    :enabled,
    :encrypted_supported,
    :env,
    :evaluate,
    :exclude_models,
    :excluded_cost_components,
    :excludes_when,
    :execution,
    :extra,
    :family,
    :features,
    :forced_choice,
    :header_name,
    :headers,
    :id,
    :image,
    :input,
    :input_audio,
    :input_video,
    :json,
    :knowledge,
    :kind,
    :last_updated,
    :lifecycle,
    :limits,
    :max,
    :max_dimensions,
    :merge,
    :meter,
    :min,
    :min_dimensions,
    :modalities,
    :mode,
    :model,
    :multiplier,
    :name,
    :native,
    :notes,
    :object,
    :output,
    :output_audio,
    :output_video,
    :parallel,
    :path,
    :per,
    :pricing,
    :pricing_defaults,
    :provider,
    :provider_model_id,
    :query_name,
    :rate,
    :rate_group,
    :rate_group_policy,
    :raw_output_supported,
    :realtime,
    :reasoning,
    :release_date,
    :replacement,
    :request,
    :required,
    :rerank,
    :retired,
    :retires_at,
    :role,
    :runtime,
    :schema,
    :size_class,
    :source,
    :speech,
    :status,
    :storage,
    :streaming,
    :strict,
    :summary_supported,
    :supported,
    :tags,
    :text,
    :thinking,
    :token_budget,
    :tool,
    :tool_calls,
    :tools,
    :training,
    :transcription,
    :transport,
    :type,
    :types,
    :unit,
    :value,
    :values,
    :video,
    :wire_protocol
  ]

  @known_snapshot_keys_by_name Map.new(@known_snapshot_keys, &{Atom.to_string(&1), &1})
  @known_snapshot_key_set MapSet.new(@known_snapshot_keys)
  @opaque_snapshot_keys MapSet.new([
                          :applies_when,
                          :default,
                          :default_headers,
                          :default_query,
                          :excludes_when,
                          :extra
                        ])

  @doc """
  Loads the packaged snapshot and applies runtime configuration.

  This is the main entry point for Phase 2 (runtime) loading. It:
  1. Loads the packaged snapshot
  2. Normalizes providers/models from v1 or v2 format
  3. Merges custom providers/models overlay
  4. Compiles and applies filters
  5. Builds indexes for O(1) queries
  6. Returns snapshot ready for Store

  ## Parameters

  - `opts` - Keyword list passed to Runtime.compile/1

  ## Returns

  - `{:ok, snapshot}` - Successfully loaded and prepared snapshot
  - `{:error, :no_snapshot}` - No packaged snapshot available
  - `{:error, term}` - Other errors

  ## Examples

      {:ok, snapshot} = Loader.load()

      {:ok, snapshot} = Loader.load(
        allow: [:openai],
        custom: %{
          local: [
            models: %{"llama-3" => %{capabilities: %{chat: true}}}
          ]
        }
      )
  """
  @spec load(keyword()) :: {:ok, map()} | {:error, term()}
  def load(opts \\ []) do
    with {:ok, {providers, models, generated_at, source_snapshot_id}} <- load_packaged(opts),
         runtime <- Runtime.compile(opts ++ [provider_ids: Enum.map(providers, & &1.id)]),
         {providers2, models2} <- merge_custom({providers, models}, runtime.custom),
         :ok <- warn_unknown_providers(runtime.unknown, providers2),
         models3 <- Pricing.apply_cost_components(models2),
         models4 <- Pricing.apply_provider_defaults(providers2, models3),
         filtered_models <- Engine.apply_filters(models4, runtime.filters),
         :ok <- validate_not_empty(filtered_models, runtime),
         snapshot <-
           build_snapshot(
             providers2,
             filtered_models,
             models4,
             runtime,
             generated_at,
             source_snapshot_id
           ) do
      {:ok, snapshot}
    end
  end

  @doc """
  Builds an empty snapshot with no providers or models.

  Used as a fallback when no packaged snapshot is available.

  ## Examples

      {:ok, snapshot} = Loader.load_empty()
  """
  @spec load_empty(keyword()) :: {:ok, map()}
  def load_empty(opts \\ []) do
    runtime = Runtime.compile(opts)

    snapshot =
      Catalog.empty(
        filters: runtime.filters,
        prefer: runtime.prefer,
        source_generated_at: nil,
        source_snapshot_id: nil,
        loaded_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        digest: compute_digest([], [], runtime)
      )

    {:ok, snapshot}
  end

  @doc """
  Computes a digest for a snapshot configuration.

  Used to detect if a reload would result in the same snapshot,
  enabling idempotent load operations.

  ## Parameters

  - `providers` - List of provider maps
  - `base_models` - List of all models before filtering
  - `runtime` - Runtime configuration map

  ## Returns

  Lowercase SHA-256 semantic fingerprint.
  """
  @spec compute_digest(list(), list(), map()) :: String.t()
  def compute_digest(providers, base_models, runtime) do
    compute_digest(providers, base_models, runtime, %{
      source_generated_at: nil,
      source_snapshot_id: nil
    })
  end

  @doc false
  @spec compute_digest(list(), list(), map(), map()) :: String.t()
  def compute_digest(providers, base_models, runtime, source_metadata) do
    semantic_catalog = %{
      version: 2,
      providers: Enum.sort_by(providers, & &1.id),
      models: Enum.sort_by(base_models, &{&1.provider, &1.id}),
      filters: runtime.filters,
      prefer: runtime.prefer,
      source: source_metadata
    }

    semantic_catalog
    |> canonical_digest_term()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # Encode maps as sorted entries so digest stability does not depend on the
  # OTP 24.1+ `:deterministic` option or on a map's internal representation.
  # Tagged composite values preserve distinctions between maps, lists, and
  # tuples while recursively removing VM-specific representation details.
  defp canonical_digest_term(%Regex{source: source, opts: opts}) do
    {:llm_db_digest_regex, source, canonical_digest_term(opts)}
  end

  defp canonical_digest_term(term) when is_map(term) do
    entries =
      term
      |> Map.to_list()
      |> Enum.map(fn {key, value} ->
        {canonical_digest_term(key), canonical_digest_term(value)}
      end)
      |> Enum.sort_by(fn {key, _value} -> :erlang.term_to_binary(key) end)

    {:llm_db_digest_map, entries}
  end

  defp canonical_digest_term(term) when is_list(term) do
    {:llm_db_digest_list, Enum.map(term, &canonical_digest_term/1)}
  end

  defp canonical_digest_term(term) when is_tuple(term) do
    {:llm_db_digest_tuple, term |> Tuple.to_list() |> Enum.map(&canonical_digest_term/1)}
  end

  defp canonical_digest_term(term), do: term

  # Private helpers
  defp load_packaged(opts) do
    with {:ok, snapshot} <- load_snapshot_document(snapshot_source(opts)) do
      deserialize_snapshot_document(snapshot)
    end
  end

  defp deserialize_snapshot_document(
         %{version: 2, providers: nested_providers, generated_at: generated_at} = snapshot
       ) do
    {providers, models} = flatten_nested_providers(nested_providers)
    deserialize_snapshot_items(providers, models, generated_at, snapshot_snapshot_id(snapshot))
  end

  defp deserialize_snapshot_document(
         %{"version" => 2, "providers" => nested_providers, "generated_at" => generated_at} =
           snapshot
       ) do
    {providers, models} = flatten_nested_providers(nested_providers)
    deserialize_snapshot_items(providers, models, generated_at, snapshot_snapshot_id(snapshot))
  end

  defp deserialize_snapshot_document(
         %{providers: providers, models: models, generated_at: generated_at} = snapshot
       )
       when is_list(providers) and is_list(models) do
    deserialize_snapshot_items(providers, models, generated_at, snapshot_snapshot_id(snapshot))
  end

  defp deserialize_snapshot_document(
         %{"providers" => providers, "models" => models, "generated_at" => generated_at} =
           snapshot
       )
       when is_list(providers) and is_list(models) do
    deserialize_snapshot_items(providers, models, generated_at, snapshot_snapshot_id(snapshot))
  end

  defp deserialize_snapshot_document(%{providers: providers, models: models} = snapshot)
       when is_list(providers) and is_list(models) do
    deserialize_snapshot_items(providers, models, nil, snapshot_snapshot_id(snapshot))
  end

  defp deserialize_snapshot_document(%{"providers" => providers, "models" => models} = snapshot)
       when is_list(providers) and is_list(models) do
    deserialize_snapshot_items(providers, models, nil, snapshot_snapshot_id(snapshot))
  end

  defp deserialize_snapshot_document(_snapshot), do: {:error, :invalid_snapshot_format}

  defp deserialize_snapshot_items(providers, models, generated_at, snapshot_id) do
    with {:ok, providers} <- deserialize_json_atoms(providers, :provider),
         {:ok, models} <- deserialize_json_atoms(models, :model) do
      {:ok, {providers, models, generated_at, snapshot_id}}
    end
  end

  defp flatten_nested_providers(nested_providers) when is_map(nested_providers) do
    {providers, all_models} =
      Enum.reduce(nested_providers, {[], []}, fn {_provider_id, provider_data},
                                                 {acc_providers, acc_models} ->
        # Extract provider without models key
        provider = map_delete(provider_data, :models)

        # Get provider ID as string for models
        provider_id_str =
          case get_value(provider_data, :id) do
            a when is_atom(a) -> Atom.to_string(a)
            s when is_binary(s) -> s
          end

        # Extract models and ensure they have provider field
        models =
          case get_value(provider_data, :models) do
            models when is_map(models) ->
              Enum.map(models, fn {_model_id, model_data} ->
                map_put_new(model_data, :provider, provider_id_str)
              end)

            _ ->
              []
          end

        {[provider | acc_providers], models ++ acc_models}
      end)

    {Enum.reverse(providers), Enum.reverse(all_models)}
  end

  defp deserialize_json_atoms(items, :provider) do
    deserialize_items(items, &normalize_provider_item/1, &Provider.new/1, :provider)
  end

  defp deserialize_json_atoms(items, :model) do
    deserialize_items(items, &normalize_model_item/1, &Model.new/1, :model)
  end

  defp deserialize_items(items, normalize, validate, type) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      with {:ok, normalized} <- normalize.(item),
           {:ok, value} <- validate.(normalized) do
        {:cont, {:ok, [value | acc]}}
      else
        {:error, reason} -> {:halt, {:error, {:invalid_snapshot_item, type, reason}}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp deserialize_modality_list(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn modality, {:ok, acc} ->
      case ValidModalities.fetch(modality) do
        {:ok, atom} -> {:cont, {:ok, [atom | acc]}}
        :error -> {:halt, {:error, {:unknown_modality, modality}}}
      end
    end)
    |> case do
      {:ok, modalities} -> {:ok, Enum.reverse(modalities)}
      error -> error
    end
  end

  defp merge_custom({providers, models}, %{providers: [], models: []}) do
    # No custom overlay
    {providers, models}
  end

  defp merge_custom({providers, models}, custom) do
    custom_providers = validate_custom_overlays!(custom.providers, :provider)
    custom_models = validate_custom_overlays!(custom.models, :model)

    merged_providers =
      providers
      |> Merge.merge_providers(custom_providers)
      |> revalidate_merged!(&Validate.validate_provider/1, "custom provider")

    merged_models =
      models
      |> Merge.merge_models(custom_models, %{})
      |> revalidate_merged!(&Validate.validate_model/1, "custom model")

    {merged_providers, merged_models}
  end

  defp validate_custom_overlays!(items, :provider) when is_list(items) do
    Enum.map(items, fn provider ->
      with {:ok, normalized} <- normalize_provider_item(provider) do
        validate_custom_overlay!(
          normalized,
          &Validate.validate_provider_overlay/1,
          "custom provider"
        )
      else
        {:error, reason} -> raise ArgumentError, "Invalid custom provider: #{inspect(reason)}"
      end
    end)
  end

  defp validate_custom_overlays!(items, :model) when is_list(items) do
    Enum.map(items, fn model ->
      with {:ok, normalized} <- normalize_model_item(model) do
        validate_custom_overlay!(normalized, &Validate.validate_model_overlay/1, "custom model")
      else
        {:error, reason} -> raise ArgumentError, "Invalid custom model: #{inspect(reason)}"
      end
    end)
  end

  defp validate_custom_overlay!(item, validator, label) do
    case validator.(item) do
      {:ok, overlay} ->
        overlay

      {:error, reason} ->
        raise ArgumentError, "Invalid #{label}: #{inspect(reason)}"
    end
  end

  defp revalidate_merged!(items, validator, label) when is_list(items) do
    Enum.map(items, fn item ->
      case validator.(item) do
        {:ok, validated} ->
          validated

        {:error, reason} ->
          raise ArgumentError, "Invalid #{label} after merge: #{inspect(reason)}"
      end
    end)
  end

  defp warn_unknown_providers([], _providers), do: :ok

  defp warn_unknown_providers(unknown_providers, providers) do
    provider_ids_set = MapSet.new(providers, & &1.id)

    Logger.warning(
      "llm_db: unknown provider(s) in filter: #{inspect(unknown_providers)}. " <>
        "Known providers: #{inspect(MapSet.to_list(provider_ids_set))}. " <>
        "Check spelling or remove unknown providers from configuration."
    )

    :ok
  end

  defp validate_not_empty(filtered_models, runtime) do
    if runtime.filters.allow != :all and filtered_models == [] do
      {:error,
       "llm_db: filters eliminated all models. Check :llm_db filter configuration. " <>
         "allow: #{summarize_filter(runtime.raw_allow)}, deny: #{summarize_filter(runtime.raw_deny)}. " <>
         "Use allow: :all to widen filters or remove deny patterns."}
    else
      :ok
    end
  end

  defp build_snapshot(
         providers,
         filtered_models,
         base_models,
         runtime,
         generated_at,
         source_snapshot_id
       ) do
    Catalog.build(providers, filtered_models, base_models,
      filters: runtime.filters,
      prefer: runtime.prefer,
      source_generated_at: generated_at,
      source_snapshot_id: source_snapshot_id,
      loaded_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      digest:
        compute_digest(providers, base_models, runtime, %{
          source_generated_at: generated_at,
          source_snapshot_id: source_snapshot_id
        })
    )
  end

  defp summarize_filter(:all), do: ":all"

  defp summarize_filter(filter) when is_map(filter) and map_size(filter) == 0 do
    "%{}"
  end

  defp summarize_filter(filter) when is_map(filter) do
    keys = Map.keys(filter) |> Enum.take(5)

    if map_size(filter) > 5 do
      "#{inspect(keys)} ... (#{map_size(filter)} providers total)"
    else
      inspect(filter)
    end
  end

  defp snapshot_source(opts) do
    base = LLMDB.Config.get()
    Keyword.get(opts, :snapshot_source, base.snapshot_source)
  end

  defp load_snapshot_document(:packaged), do: Packaged.load()

  defp load_snapshot_document({:file, path}) when is_binary(path) do
    Snapshot.read(path, integrity_policy: integrity_policy())
  end

  defp load_snapshot_document({:github_releases, store_opts}) do
    {ref, overrides} = release_ref_and_overrides(store_opts)

    case ReleaseStore.fetch_snapshot(ref, overrides) do
      {:ok, %{snapshot: snapshot}} -> {:ok, snapshot}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_snapshot_document(other) when is_binary(other),
    do: load_snapshot_document({:file, other})

  defp load_snapshot_document(_), do: Packaged.load()

  defp integrity_policy do
    Application.get_env(:llm_db, :integrity_policy, :strict)
  end

  defp release_ref_and_overrides(store_opts) do
    normalized =
      cond do
        is_map(store_opts) -> store_opts
        Keyword.keyword?(store_opts) -> Enum.into(store_opts, %{})
        true -> %{}
      end

    ref =
      Map.get(normalized, :ref) ||
        Map.get(normalized, "ref") ||
        :latest

    overrides =
      normalized
      |> Map.delete(:ref)
      |> Map.delete("ref")

    {ref, overrides}
  end

  defp snapshot_snapshot_id(snapshot) when is_map(snapshot) do
    snapshot["snapshot_id"] || snapshot[:snapshot_id]
  end

  defp provider_atom(provider) when is_atom(provider), do: {:ok, provider}

  defp provider_atom(provider) when is_binary(provider) do
    case ProviderRegistry.fetch(provider) do
      {:ok, atom} ->
        {:ok, atom}

      :error ->
        try do
          {:ok, String.to_existing_atom(provider)}
        rescue
          ArgumentError -> {:error, {:unknown_provider_id, provider}}
        end
    end
  end

  defp provider_atom(provider), do: {:error, {:invalid_provider_id, provider}}

  defp normalize_provider_item(provider) do
    case provider do
      %Provider{} ->
        {:ok, provider}

      provider when is_map(provider) ->
        with {:ok, normalized_id} <- provider_atom(get_value(provider, :id)) do
          {:ok,
           provider
           |> atomize_known_keys()
           |> Map.put(:id, normalized_id)}
        end

      _other ->
        {:error, :invalid_provider}
    end
  end

  defp normalize_model_item(%Model{} = model), do: {:ok, model}

  defp normalize_model_item(model) when is_map(model) do
    with {:ok, normalized_provider} <- provider_atom(get_value(model, :provider)),
         {:ok, normalized_model} <- normalize_model_modalities(model) do
      {:ok,
       normalized_model
       |> atomize_known_keys()
       |> Map.put(:provider, normalized_provider)}
    end
  end

  defp normalize_model_item(_model), do: {:error, :invalid_model}

  defp normalize_model_modalities(model) do
    case get_value(model, :modalities) do
      modalities when is_map(modalities) ->
        with {:ok, normalized} <- maybe_normalize_modality(modalities, :input),
             {:ok, normalized} <- maybe_normalize_modality(normalized, :output) do
          {:ok, put_value(model, :modalities, normalized)}
        end

      _other ->
        {:ok, model}
    end
  end

  defp maybe_normalize_modality(modalities, key) do
    case get_value(modalities, key) do
      list when is_list(list) ->
        with {:ok, normalized} <- deserialize_modality_list(list) do
          {:ok, put_value(modalities, key, normalized)}
        end

      _other ->
        {:ok, modalities}
    end
  end

  defp get_value(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp put_value(%_{} = struct, key, value), do: Map.put(struct, key, value)

  defp put_value(map, key, value) when is_map(map) do
    cond do
      Map.has_key?(map, key) -> Map.put(map, key, value)
      Map.has_key?(map, Atom.to_string(key)) -> Map.put(map, Atom.to_string(key), value)
      true -> Map.put(map, key, value)
    end
  end

  defp map_put_new(%_{} = struct, key, value), do: Map.put_new(struct, key, value)

  defp map_put_new(map, key, value) when is_map(map) do
    cond do
      Map.has_key?(map, key) -> map
      Map.has_key?(map, Atom.to_string(key)) -> map
      true -> Map.put(map, key, value)
    end
  end

  defp map_delete(%_{} = struct, key), do: Map.delete(struct, key)

  defp map_delete(map, key) when is_map(map) do
    map
    |> Map.delete(key)
    |> Map.delete(Atom.to_string(key))
  end

  defp atomize_known_keys(%_{} = struct), do: struct

  defp atomize_known_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      normalized_key = normalize_known_key(key)

      normalized_value =
        cond do
          MapSet.member?(@opaque_snapshot_keys, normalized_key) -> value
          MapSet.member?(@known_snapshot_key_set, normalized_key) -> atomize_known_keys(value)
          true -> value
        end

      {normalized_key, normalized_value}
    end)
  end

  defp atomize_known_keys(list) when is_list(list), do: Enum.map(list, &atomize_known_keys/1)
  defp atomize_known_keys(value), do: value

  defp normalize_known_key(key) when is_atom(key), do: key

  defp normalize_known_key(key) when is_binary(key) do
    Map.get(@known_snapshot_keys_by_name, key, key)
  end
end
