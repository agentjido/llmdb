defmodule LLMDB.Query do
  @moduledoc """
  Query functions for selecting models based on capabilities and model size.

  Provides capability-based model selection with provider preferences and
  optional hardware-related sorting.
  All queries operate on the filtered catalog loaded into the Store.
  """

  alias LLMDB.{Catalog, Model, Spec}

  @type provider :: atom()
  @type model_id :: String.t()
  @type model_spec :: {provider(), model_id()} | String.t() | Model.t()

  # Maps query capability keys to their paths in the Model.capabilities schema.
  # This map is the single source of truth for capability lookups, derived from
  # the capability schema in LLMDB.Model. Top-level capabilities like :chat and
  # :embeddings map to single-element paths, while nested capabilities like
  # :tools_streaming map to [:tools, :streaming].
  @capability_paths %{
    chat: [:chat],
    embeddings: [:embeddings],
    reasoning: [:reasoning, :enabled],
    rerank: [:rerank],
    tools: [:tools, :enabled],
    tools_streaming: [:tools, :streaming],
    tools_strict: [:tools, :strict],
    tools_parallel: [:tools, :parallel],
    json_native: [:json, :native],
    json_schema: [:json, :schema],
    json_strict: [:json, :strict],
    streaming_text: [:streaming, :text],
    streaming_tool_calls: [:streaming, :tool_calls]
  }

  @sort_fields [:total_parameters, :active_parameters, :minimum_ram_gb, :minimum_vram_gb]

  @doc """
  Selects the first model matching capability requirements.

  Returns the first allowed model that matches the required capabilities.
  Provider preference controls the order unless `:sort_by` is set.

  ## Options

  - `:require` - Keyword list of required capabilities (e.g., `[tools: true, json_native: true]`)
  - `:forbid` - Keyword list of forbidden capabilities
  - `:prefer` - List of provider atoms in preference order (e.g., `[:openai, :anthropic]`)
  - `:scope` - Either `:all` (default) or a specific provider atom
  - `:sort_by` - `:total_parameters`, `:active_parameters`, `:minimum_ram_gb`, or
    `:minimum_vram_gb` from optional `extra.llmfit` metadata
  - `:sort_order` - `:asc` (default) or `:desc`; models without a numeric value are last

  ## Returns

  - `{:ok, {provider, model_id}}` - First matching model
  - `{:error, :no_match}` - No models match the criteria

  ## Examples

      {:ok, {provider, model_id}} = Query.select(
        require: [chat: true, tools: true],
        prefer: [:openai, :anthropic]
      )

      {:ok, {:openai, model_id}} = Query.select(
        require: [json_native: true],
        scope: :openai
      )

      {:ok, {provider, model_id}} = Query.select(
        sort_by: :total_parameters
      )
  """
  @spec select(keyword()) :: {:ok, {provider(), model_id()}} | {:error, :no_match}
  def select(opts \\ []) do
    require_kw = Keyword.get(opts, :require, [])
    forbid_kw = Keyword.get(opts, :forbid, [])
    scope = Keyword.get(opts, :scope, :all)
    sort_by = opts |> Keyword.get(:sort_by) |> validate_sort_by!()
    sort_order = opts |> Keyword.get(:sort_order, :asc) |> validate_sort_order!()

    # Use snapshot.prefer as default if :prefer not explicitly provided
    prefer =
      case Keyword.fetch(opts, :prefer) do
        :error ->
          Catalog.prefer()

        {:ok, p} ->
          p
      end

    providers = build_provider_list(scope, prefer)

    case sort_by do
      nil ->
        find_first_match(providers, require_kw, forbid_kw)

      _ ->
        providers
        |> find_all_matching_models(require_kw, forbid_kw)
        |> sort_candidates(sort_by, sort_order)
        |> case do
          [] -> {:error, :no_match}
          [{provider, model} | _] -> {:ok, {provider, model.id}}
        end
    end
  end

  @doc """
  Gets all allowed models matching capability requirements.

  Returns all models that match the capability filters. Provider preference
  controls the order unless `:sort_by` is set. Similar to `select/1` but
  returns all matches instead of only the first.

  ## Options

  - `:require` - Keyword list of required capabilities (e.g., `[tools: true, json_native: true]`)
  - `:forbid` - Keyword list of forbidden capabilities
  - `:prefer` - List of provider atoms in preference order (e.g., `[:openai, :anthropic]`)
  - `:scope` - Either `:all` (default) or a specific provider atom
  - `:sort_by` - `:total_parameters`, `:active_parameters`, `:minimum_ram_gb`, or
    `:minimum_vram_gb` from optional `extra.llmfit` metadata
  - `:sort_order` - `:asc` (default) or `:desc`; models without a numeric value are last

  ## Returns

  List of `{provider, model_id}` tuples matching the criteria.

  ## Examples

      candidates = Query.candidates(
        require: [chat: true, tools: true],
        prefer: [:openai, :anthropic]
      )
      #=> [{:openai, "gpt-4o"}, {:openai, "gpt-4o-mini"}, {:anthropic, "claude-3-5-sonnet-20241022"}, ...]

      candidates = Query.candidates(
        require: [json_native: true],
        scope: :openai
      )
      #=> [{:openai, "gpt-4o"}, {:openai, "gpt-4o-mini"}, ...]

      local_candidates = Query.candidates(
        sort_by: :minimum_ram_gb
      )
  """
  @spec candidates(keyword()) :: [{provider(), model_id()}]
  def candidates(opts \\ []) do
    require_kw = Keyword.get(opts, :require, [])
    forbid_kw = Keyword.get(opts, :forbid, [])
    scope = Keyword.get(opts, :scope, :all)
    sort_by = opts |> Keyword.get(:sort_by) |> validate_sort_by!()
    sort_order = opts |> Keyword.get(:sort_order, :asc) |> validate_sort_order!()

    prefer =
      case Keyword.fetch(opts, :prefer) do
        :error ->
          Catalog.prefer()

        {:ok, p} ->
          p
      end

    providers = build_provider_list(scope, prefer)

    providers
    |> find_all_matching_models(require_kw, forbid_kw)
    |> sort_candidates(sort_by, sort_order)
    |> Enum.map(fn {provider, model} -> {provider, model.id} end)
  end

  @doc """
  Gets capabilities for a model spec.

  Returns capabilities map or nil if model not found.

  ## Parameters

  - `spec` - Either `{provider, model_id}` tuple, `"provider:model"` string, or `%Model{}` struct

  ## Examples

      caps = Query.capabilities({:openai, "gpt-4o-mini"})
      #=> %{chat: true, tools: %{enabled: true, ...}, ...}

      caps = Query.capabilities("openai:gpt-4o-mini")
      #=> %{chat: true, tools: %{enabled: true, ...}, ...}

      {:ok, model} = LLMDB.model("openai:gpt-4o-mini")
      caps = Query.capabilities(model)
      #=> %{chat: true, tools: %{enabled: true, ...}, ...}
  """
  @spec capabilities(model_spec()) :: map() | nil
  def capabilities(%Model{capabilities: caps}), do: caps

  def capabilities({provider, model_id}) when is_atom(provider) and is_binary(model_id) do
    case Catalog.model(provider, model_id) do
      {:ok, m} -> Map.get(m, :capabilities)
      _ -> nil
    end
  end

  def capabilities(spec) when is_binary(spec) do
    case Spec.parse_spec(spec) do
      {:ok, {p, id}} -> capabilities({p, id})
      _ -> nil
    end
  end

  # Private helpers

  defp build_provider_list(:all, prefer) do
    all_providers = Catalog.providers() |> Enum.map(&Map.get(&1, :id, Map.get(&1, "id")))

    if prefer != [] do
      prefer ++ (all_providers -- prefer)
    else
      all_providers
    end
  end

  defp build_provider_list(provider, _prefer) when is_atom(provider) do
    [provider]
  end

  defp find_all_matching_models(providers, require_kw, forbid_kw) do
    Enum.flat_map(providers, fn provider ->
      Catalog.models(provider)
      |> Enum.filter(&matches_require?(&1, require_kw))
      |> Enum.reject(&matches_forbid?(&1, forbid_kw))
      |> Enum.map(&{provider, &1})
    end)
  end

  defp find_first_match([], _require_kw, _forbid_kw), do: {:error, :no_match}

  defp find_first_match([provider | rest], require_kw, forbid_kw) do
    models_list =
      Catalog.models(provider)
      |> Enum.filter(&matches_require?(&1, require_kw))
      |> Enum.reject(&matches_forbid?(&1, forbid_kw))

    case models_list do
      [] -> find_first_match(rest, require_kw, forbid_kw)
      [model | _] -> {:ok, {provider, model.id}}
    end
  end

  defp validate_sort_by!(nil), do: nil
  defp validate_sort_by!(sort_by) when sort_by in @sort_fields, do: sort_by

  defp validate_sort_by!(sort_by) do
    raise ArgumentError,
          "sort_by must be one of #{inspect(@sort_fields)}, got: #{inspect(sort_by)}"
  end

  defp validate_sort_order!(sort_order) when sort_order in [:asc, :desc], do: sort_order

  defp validate_sort_order!(sort_order) do
    raise ArgumentError, "sort_order must be :asc or :desc, got: #{inspect(sort_order)}"
  end

  defp sort_candidates(candidates, nil, _sort_order), do: candidates

  defp sort_candidates(candidates, sort_by, sort_order) do
    candidates
    |> Enum.with_index()
    |> Enum.sort_by(fn {{_provider, model}, index} ->
      case model_sort_value(model, sort_by) do
        value when is_number(value) ->
          ordered_value = if sort_order == :asc, do: value, else: -value
          {0, ordered_value, index}

        _ ->
          {1, 0, index}
      end
    end)
    |> Enum.map(&elem(&1, 0))
  end

  defp model_sort_value(model, :total_parameters) do
    model |> llmfit_metadata() |> metadata_value(:parameters_raw)
  end

  defp model_sort_value(model, :active_parameters) do
    model
    |> llmfit_metadata()
    |> metadata_value(:moe)
    |> metadata_value(:active_parameters)
  end

  defp model_sort_value(model, :minimum_ram_gb) do
    model
    |> llmfit_metadata()
    |> metadata_value(:memory)
    |> metadata_value(:min_ram_gb)
  end

  defp model_sort_value(model, :minimum_vram_gb) do
    model
    |> llmfit_metadata()
    |> metadata_value(:memory)
    |> metadata_value(:min_vram_gb)
  end

  defp llmfit_metadata(model), do: metadata_value(Map.get(model, :extra), :llmfit)

  defp metadata_value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp metadata_value(_map, _key), do: nil

  defp matches_require?(_model, []), do: true

  defp matches_require?(model, require_kw) do
    caps = Map.get(model, :capabilities) || %{}

    Enum.all?(require_kw, fn {key, value} ->
      check_capability(caps, key, value)
    end)
  end

  defp matches_forbid?(_model, []), do: false

  defp matches_forbid?(model, forbid_kw) do
    caps = Map.get(model, :capabilities) || %{}

    Enum.any?(forbid_kw, fn {key, value} ->
      check_capability(caps, key, value)
    end)
  end

  defp check_capability(caps, key, expected_value) do
    case Map.get(@capability_paths, key) do
      nil -> false
      path -> get_in(caps, path) == expected_value
    end
  end
end
