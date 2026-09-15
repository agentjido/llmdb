defmodule LLMDB.Catalog do
  @moduledoc false

  @store_key :llm_db_store
  @load_resource {__MODULE__, :load}
  @provider_aliases %{google_vertex_anthropic: :google_vertex}
  @bedrock_prefixes ~w(us. eu. ap. apac. ca. au. jp. us-gov. global.)

  @typedoc false
  @type t :: map()

  @spec build(list(), list(), list(), keyword()) :: t()
  def build(providers, filtered_models, base_models, opts)
      when is_list(providers) and is_list(filtered_models) and is_list(base_models) and
             is_list(opts) do
    providers = apply_provider_aliases(providers)

    %{
      providers_by_id: index_providers(providers),
      models_by_key: index_models(filtered_models),
      aliases_by_key: index_aliases(filtered_models),
      providers: providers,
      models: Enum.group_by(filtered_models, & &1.provider),
      base_models: base_models,
      filters: Keyword.fetch!(opts, :filters),
      prefer: Keyword.get(opts, :prefer, []),
      meta: %{
        epoch: nil,
        source_generated_at: Keyword.get(opts, :source_generated_at),
        source_snapshot_id: Keyword.get(opts, :source_snapshot_id),
        loaded_at: Keyword.fetch!(opts, :loaded_at),
        digest: Keyword.fetch!(opts, :digest)
      }
    }
    |> put_resolution_indexes(filtered_models)
  end

  @spec empty(keyword()) :: t()
  def empty(opts) when is_list(opts) do
    build([], [], [], opts)
  end

  @spec with_runtime_view(t(), list(), map()) :: t()
  def with_runtime_view(catalog, filtered_models, filters)
      when is_map(catalog) and is_list(filtered_models) and is_map(filters) do
    catalog
    |> Map.merge(%{
      filters: filters,
      models_by_key: index_models(filtered_models),
      aliases_by_key: index_aliases(filtered_models),
      models: Enum.group_by(filtered_models, & &1.provider)
    })
    |> put_resolution_indexes(filtered_models)
  end

  @spec with_prefer(t(), [atom()]) :: t()
  def with_prefer(catalog, prefer) when is_map(catalog) and is_list(prefer) do
    Map.put(catalog, :prefer, prefer)
  end

  # Persistent storage belongs to the catalog boundary. Store remains a
  # compatibility facade, while Spec and Query can depend on Catalog directly
  # without forming Model -> Spec -> Store -> Model.
  @spec get() :: map() | nil
  def get, do: :persistent_term.get(@store_key, nil)

  @spec snapshot() :: t() | nil
  def snapshot do
    case get() do
      %{snapshot: snapshot} -> snapshot
      _ -> nil
    end
  end

  @spec epoch() :: non_neg_integer()
  def epoch do
    case get() do
      %{epoch: epoch} -> epoch
      _ -> 0
    end
  end

  @spec last_opts() :: keyword()
  def last_opts do
    case get() do
      %{opts: opts} -> opts
      _ -> []
    end
  end

  @spec put!(t(), keyword()) :: :ok
  def put!(catalog, opts) when is_map(catalog) and is_list(opts) do
    epoch = :erlang.unique_integer([:monotonic, :positive])
    :persistent_term.put(@store_key, %{snapshot: catalog, epoch: epoch, opts: opts})
    :ok
  end

  @spec clear!() :: :ok
  def clear! do
    :persistent_term.erase(@store_key)
    :ok
  end

  @spec load((-> result)) :: result when result: term()
  def load(fun) when is_function(fun, 0), do: with_load_lock(fun)

  @spec ensure_loaded() :: :ok | {:error, term()}
  def ensure_loaded do
    cond do
      not is_nil(snapshot()) ->
        :ok

      skip_packaged_load?() ->
        :ok

      true ->
        with_load_lock(fn ->
          cond do
            not is_nil(snapshot()) -> :ok
            skip_packaged_load?() -> :ok
            true -> lazy_load()
          end
        end)
    end
  end

  @spec ensure_loaded!() :: :ok
  def ensure_loaded! do
    case ensure_loaded() do
      :ok -> :ok
      {:error, reason} -> raise LLMDB.LoadError, reason: reason
    end
  end

  @spec providers(t() | nil) :: list()
  def providers(%{providers: providers}) when is_list(providers), do: providers
  def providers(_catalog), do: []

  @spec providers() :: list()
  def providers do
    ensure_loaded!()
    providers(snapshot())
  end

  @spec provider(t() | nil, atom()) :: {:ok, map()} | {:error, :not_found}
  def provider(%{providers_by_id: providers}, provider_id)
      when is_map(providers) and is_atom(provider_id) do
    case Map.fetch(providers, provider_id) do
      {:ok, provider} -> {:ok, provider}
      :error -> {:error, :not_found}
    end
  end

  def provider(_catalog, _provider_id), do: {:error, :not_found}

  @spec provider(atom()) :: {:ok, map()} | {:error, :not_found}
  def provider(provider_id) do
    ensure_loaded!()
    provider(snapshot(), provider_id)
  end

  @spec provider_exists?(t() | nil, atom()) :: boolean()
  def provider_exists?(%{providers_by_id: providers}, provider_id)
      when is_map(providers) and is_atom(provider_id) do
    Map.has_key?(providers, provider_id)
  end

  def provider_exists?(_catalog, _provider_id), do: false

  @spec provider_exists?(atom()) :: boolean()
  def provider_exists?(provider_id) do
    ensure_loaded!()
    provider_exists?(snapshot(), provider_id)
  end

  @spec models(t() | nil, atom()) :: list()
  def models(catalog, provider_id) when is_map(catalog) and is_atom(provider_id) do
    models = Map.get(catalog, :models) || Map.get(catalog, :models_by_provider) || %{}

    if is_map(models) do
      catalog
      |> provider_lookup_ids(provider_id)
      |> Enum.flat_map(&Map.get(models, &1, []))
      |> Enum.uniq_by(&field(&1, :id))
    else
      []
    end
  end

  def models(_catalog, _provider_id), do: []

  @spec models(atom()) :: list()
  def models(provider_id) do
    ensure_loaded!()
    models(snapshot(), provider_id)
  end

  @spec model(t() | nil, atom(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def model(catalog, provider_id, model_id)
      when is_atom(provider_id) and is_binary(model_id) do
    case resolve_model(catalog, provider_id, model_id) do
      {:ok, {_provider, _canonical_id, model}} -> {:ok, model}
      {:error, :not_found} = error -> error
    end
  end

  @spec model(atom(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def model(provider_id, model_id) do
    ensure_loaded!()
    model(snapshot(), provider_id, model_id)
  end

  @spec resolve_model(atom(), String.t()) ::
          {:ok, {atom(), String.t(), map()}} | {:error, :not_found}
  def resolve_model(provider_id, model_id) do
    ensure_loaded!()
    resolve_model(snapshot(), provider_id, model_id)
  end

  @spec resolve_model(t() | nil, atom(), String.t()) ::
          {:ok, {atom(), String.t(), map()}} | {:error, :not_found}
  def resolve_model(nil, _provider_id, _model_id), do: {:error, :not_found}

  # A Bedrock inference profile id is looked up as given first: the catalog
  # carries regional entries (`eu.`, `au.`, ...) with their own pricing. Only
  # when none exists does the id fall back to the base model it routes to.
  def resolve_model(catalog, provider_id, model_id)
      when is_map(catalog) and is_atom(provider_id) and is_binary(model_id) do
    {stripped_id, prefix} = strip_prefix(provider_id, model_id)

    direct =
      if prefix do
        lookup_model(catalog, provider_id, model_id, true) ||
          lookup_model(catalog, provider_id, model_id)
      else
        lookup_model(catalog, provider_id, model_id)
      end

    case direct do
      {actual_provider, canonical_id, model} ->
        returned_id = preserve_prefix(canonical_id, prefix)

        {:ok, {provider_id, returned_id, normalize_provider(model, actual_provider, provider_id)}}

      nil when is_nil(prefix) ->
        {:error, :not_found}

      nil ->
        case lookup_model(catalog, provider_id, stripped_id) do
          nil ->
            {:error, :not_found}

          {actual_provider, canonical_id, model} ->
            {:ok,
             {provider_id, prefix <> canonical_id,
              normalize_provider(model, actual_provider, provider_id)}}
        end
    end
  end

  defp lookup_model(catalog, provider_id, lookup_id, canonical_only \\ false) do
    catalog
    |> provider_lookup_ids(provider_id)
    |> Enum.find_value(fn actual_provider ->
      case fetch_model(catalog, actual_provider, lookup_id, canonical_only) do
        nil -> nil
        {canonical_id, model} -> {actual_provider, canonical_id, model}
      end
    end)
  end

  defp preserve_prefix(canonical_id, nil), do: canonical_id

  defp preserve_prefix(canonical_id, prefix) do
    case strip_prefix(:amazon_bedrock, canonical_id) do
      {_base_id, nil} -> prefix <> canonical_id
      {_base_id, _regional_prefix} -> canonical_id
    end
  end

  @spec resolve_bare(t() | nil, String.t()) ::
          {:ok, {atom(), String.t(), map()}} | {:error, :not_found | :ambiguous}
  def resolve_bare(nil, _model_id), do: {:error, :not_found}

  def resolve_bare(catalog, model_id) when is_map(catalog) and is_binary(model_id) do
    {_bedrock_id, bedrock_prefix} = strip_prefix(:amazon_bedrock, model_id)

    direct =
      catalog
      |> resolutions_by_model_id()
      |> Map.get(model_id, [])
      |> Enum.reject(fn {provider, _canonical_id, _model} ->
        bedrock_prefix && provider == :amazon_bedrock
      end)

    prefixed_bedrock =
      if bedrock_prefix do
        case resolve_model(catalog, :amazon_bedrock, model_id) do
          {:ok, resolution} -> [resolution]
          {:error, :not_found} -> []
        end
      else
        []
      end

    matches =
      (direct ++ prefixed_bedrock)
      |> Enum.uniq_by(fn {provider, canonical_id, _model} -> {provider, canonical_id} end)

    case matches do
      [] -> {:error, :not_found}
      [match] -> {:ok, match}
      [_ | _] -> {:error, :ambiguous}
    end
  end

  @spec resolve_bare(String.t()) ::
          {:ok, {atom(), String.t(), map()}} | {:error, :not_found | :ambiguous}
  def resolve_bare(model_id) do
    ensure_loaded!()
    resolve_bare(snapshot(), model_id)
  end

  @spec strip_prefix(atom(), String.t()) :: {String.t(), String.t() | nil}
  def strip_prefix(:amazon_bedrock, model_id) when is_binary(model_id) do
    case Enum.find_value(@bedrock_prefixes, fn prefix ->
           if String.starts_with?(model_id, prefix) do
             {String.replace_prefix(model_id, prefix, ""), prefix}
           end
         end) do
      nil -> {model_id, nil}
      result -> result
    end
  end

  def strip_prefix(_provider, model_id) when is_binary(model_id), do: {model_id, nil}

  @spec prefer(t() | nil) :: [atom()]
  def prefer(%{prefer: prefer}) when is_list(prefer), do: prefer
  def prefer(_catalog), do: []

  @spec prefer() :: [atom()]
  def prefer do
    ensure_loaded!()
    prefer(snapshot())
  end

  defp with_load_lock(fun) do
    :global.trans({@load_resource, self()}, fun, [node()])
  end

  defp lazy_load do
    # Avoid a compile-time Catalog -> LLMDB edge: the facade already depends on
    # Catalog, and this callback exists only to enter the normal load pipeline.
    case :erlang.apply(:"Elixir.LLMDB", :__lazy_load__, [[]]) do
      {:ok, _catalog} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp skip_packaged_load? do
    Application.get_env(:llm_db, :skip_packaged_load, false)
  end

  defp put_resolution_indexes(catalog, models) do
    Map.merge(catalog, %{
      __llm_db_provider_lookup_ids__: index_provider_lookup_ids(catalog.providers),
      __llm_db_resolutions_by_model_id__: index_resolutions(models)
    })
  end

  defp apply_provider_aliases(providers) do
    Enum.map(providers, fn provider ->
      case Map.get(@provider_aliases, field(provider, :id)) do
        nil -> provider
        primary_id -> Map.put(provider, :alias_of, primary_id)
      end
    end)
  end

  defp index_providers(providers), do: Map.new(providers, &{field(&1, :id), &1})

  defp index_models(models) do
    Map.new(models, &{{field(&1, :provider), field(&1, :id)}, &1})
  end

  defp index_aliases(models) do
    models
    |> Enum.flat_map(fn model ->
      provider = field(model, :provider)
      canonical_id = field(model, :id)

      Enum.map(field(model, :aliases) || [], fn alias_name ->
        {{provider, alias_name}, canonical_id}
      end)
    end)
    |> Map.new()
  end

  defp index_provider_lookup_ids(providers) do
    provider_ids_by_name =
      Map.new(providers, fn provider ->
        provider_id = field(provider, :id)
        {to_string(provider_id), provider_id}
      end)

    Enum.reduce(providers, %{}, fn provider, acc ->
      provider_id = field(provider, :id)
      alias_of = normalize_provider_id(field(provider, :alias_of), provider_ids_by_name)
      acc = Map.put_new(acc, provider_id, [provider_id])

      if is_atom(alias_of) do
        Map.update(acc, alias_of, [alias_of, provider_id], fn ids ->
          Enum.uniq(ids ++ [provider_id])
        end)
      else
        acc
      end
    end)
  end

  defp index_resolutions(models) do
    direct =
      Map.new(models, fn model ->
        provider = field(model, :provider)
        canonical_id = field(model, :id)
        {{provider, canonical_id}, {provider, canonical_id, model}}
      end)

    aliases =
      Enum.reduce(models, %{}, fn model, acc ->
        provider = field(model, :provider)
        canonical_id = field(model, :id)
        resolution = {provider, canonical_id, model}

        Enum.reduce(field(model, :aliases) || [], acc, fn alias_name, entries ->
          Map.put(entries, {provider, alias_name}, resolution)
        end)
      end)

    direct
    |> Map.merge(aliases)
    |> Enum.group_by(
      fn {{_provider, lookup_id}, _resolution} -> lookup_id end,
      fn {_key, resolution} -> resolution end
    )
    |> Map.new(fn {lookup_id, resolutions} ->
      {lookup_id, Enum.sort_by(resolutions, fn {provider, _canonical_id, _model} -> provider end)}
    end)
  end

  defp provider_lookup_ids(catalog, provider_id) do
    catalog
    |> provider_lookup_index()
    |> Map.get(provider_id, [provider_id])
  end

  defp provider_lookup_index(%{__llm_db_provider_lookup_ids__: index}) when is_map(index),
    do: index

  defp provider_lookup_index(catalog), do: index_provider_lookup_ids(providers(catalog))

  defp resolutions_by_model_id(%{__llm_db_resolutions_by_model_id__: index})
       when is_map(index),
       do: index

  defp resolutions_by_model_id(catalog) do
    models =
      cond do
        is_map(Map.get(catalog, :models)) ->
          catalog |> Map.fetch!(:models) |> Map.values() |> List.flatten()

        is_map(Map.get(catalog, :models_by_provider)) ->
          catalog |> Map.fetch!(:models_by_provider) |> Map.values() |> List.flatten()

        is_map(Map.get(catalog, :models_by_key)) ->
          catalog |> Map.fetch!(:models_by_key) |> Map.values()

        true ->
          []
      end

    index_resolutions(models)
  end

  defp fetch_model(catalog, provider, lookup_id, canonical_only) do
    key = {provider, lookup_id}

    canonical_id =
      if canonical_only, do: lookup_id, else: Map.get(catalog.aliases_by_key, key, lookup_id)

    case Map.get(catalog.models_by_key, {provider, canonical_id}) do
      nil -> nil
      model -> {canonical_id, model}
    end
  end

  defp normalize_provider(model, provider, requested_provider)
       when provider != requested_provider do
    Map.put(model, :provider, requested_provider)
  end

  defp normalize_provider(model, _provider, _requested_provider), do: model

  defp normalize_provider_id(provider_id, _provider_ids_by_name) when is_atom(provider_id),
    do: provider_id

  defp normalize_provider_id(provider_id, provider_ids_by_name) when is_binary(provider_id),
    do: Map.get(provider_ids_by_name, provider_id)

  defp normalize_provider_id(_provider_id, _provider_ids_by_name), do: nil

  defp field(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end
end
