defmodule LLMDB.Pricing do
  @moduledoc """
  Pricing pipeline for converting legacy cost data and applying provider defaults.

  This module handles two key transformations during snapshot loading:

  1. **Legacy cost conversion** - Converts the simple `cost` map (input/output/cache rates)
     into the flexible `pricing.components` format for backward compatibility.

  2. **Provider defaults** - Merges provider-level pricing defaults (e.g., tool pricing)
     into each model's pricing, respecting merge strategies.

  ## Pipeline

  The pricing transformations run during `LLMDB.Loader.load/1`:

      models
      |> Pricing.apply_cost_components()      # Convert cost -> pricing.components
      |> Pricing.apply_provider_defaults()    # Merge provider defaults

  ## Pricing Structure

  The `pricing` field on models contains:

      %{
        currency: "USD",
        merge: "merge_by_id",  # or "replace"
        components: [
          %{id: "token.input", kind: "token", unit: "token", per: 1_000_000, rate: 3.0},
          %{id: "tool.web_search", kind: "tool", tool: "web_search", unit: "call", per: 1000, rate: 10.0}
        ]
      }

  See the [Pricing and Billing guide](pricing-and-billing.md) for full documentation.
  """

  alias LLMDB.Merge

  @doc """
  Converts legacy `cost` fields to `pricing.components` format.

  For each model with a `cost` map, generates corresponding pricing components:

  | Cost Field | Component ID |
  |------------|--------------|
  | `input` | `token.input` |
  | `output` | `token.output` |
  | `cache_read` | `token.cache_read` |
  | `cache_write` | `token.cache_write` |
  | `reasoning` | `token.reasoning` |

  Existing `pricing.components` are preserved and take precedence over
  generated components (merged by ID).

  ## Examples

      iex> models = [%{id: "gpt-4", provider: :openai, cost: %{input: 3.0, output: 15.0}}]
      iex> [model] = LLMDB.Pricing.apply_cost_components(models)
      iex> model.pricing.components
      [
        %{id: "token.input", kind: "token", unit: "token", per: 1_000_000, rate: 3.0},
        %{id: "token.output", kind: "token", unit: "token", per: 1_000_000, rate: 15.0}
      ]
  """
  @spec apply_cost_components([LLMDB.Model.t()]) :: [LLMDB.Model.t()]
  def apply_cost_components(models) when is_list(models) do
    Enum.map(models, &apply_cost_components_to_model/1)
  end

  @doc """
  Applies provider-level pricing defaults to models.

  For each model, looks up its provider's `pricing_defaults` and merges them
  into the model's `pricing` field. The merge behavior depends on the model's
  `pricing.merge` setting:

  - `"merge_by_id"` (default) - Provider defaults are merged with model components
    by ID. Model components override matching defaults.
  - `"replace"` - Model pricing completely replaces provider defaults.

  Models without existing `pricing` inherit the full provider defaults.

  ## Examples

      iex> providers = [%{id: :openai, pricing_defaults: %{
      ...>   currency: "USD",
      ...>   components: [%{id: "tool.web_search", kind: "tool", rate: 10.0}]
      ...> }}]
      iex> models = [%{id: "gpt-4", provider: :openai, pricing: nil}]
      iex> [model] = LLMDB.Pricing.apply_provider_defaults(providers, models)
      iex> model.pricing.components
      [%{id: "tool.web_search", kind: "tool", rate: 10.0}]
  """
  @spec apply_provider_defaults([LLMDB.Provider.t()], [LLMDB.Model.t()]) :: [LLMDB.Model.t()]
  def apply_provider_defaults(providers, models) when is_list(providers) and is_list(models) do
    defaults_by_provider =
      Map.new(providers, fn provider ->
        {provider.id, Map.get(provider, :pricing_defaults)}
      end)

    Enum.map(models, fn model ->
      case Map.get(defaults_by_provider, model.provider) do
        nil -> model
        defaults -> apply_defaults_to_model(model, defaults)
      end
    end)
  end

  @doc """
  Selects pricing components that apply for a request context.

  This helper does not calculate final cost. It separates components with fully
  satisfied conditions from components that cannot be resolved because the
  supplied context is incomplete. Missing or `nil` context values are unknown;
  a known non-matching application condition or matching exclusion rules a
  component out even if another condition is unknown.

  Conditions are conjunctive and accept atom or string keys, nested maps, and
  numeric `gt`/`gte`/`lt`/`lte` comparisons. Selected components are returned
  unchanged: callers must resolve derived rates and apply matching modifiers
  once. This helper neither resolves overlapping rate components nor validates
  provider request eligibility. See the pricing guide for current-model examples.

  ## Examples

      iex> model = %{pricing: %{components: [
      ...>   %{id: "token.input", rate: 5.0},
      ...>   %{id: "token.input.long_context", rate: 10.0, applies_when: %{input_tokens: %{gt: 272_000}}}
      ...> ]}}
      iex> LLMDB.Pricing.components_for(model, input_tokens: 900_000).components |> Enum.map(& &1.id)
      ["token.input", "token.input.long_context"]
  """
  @spec components_for(map(), map() | keyword()) :: %{components: [map()], unresolved: [map()]}
  def components_for(model, context \\ %{}) when is_map(model) do
    request_context = context_map(context)

    model
    |> Map.get(:pricing, Map.get(model, "pricing", %{}))
    |> components_list()
    |> Enum.reduce(%{components: [], unresolved: []}, fn component, acc ->
      case component_status(component, request_context) do
        :applies -> update_in(acc.components, &(&1 ++ [component]))
        :unresolved -> update_in(acc.unresolved, &(&1 ++ [component]))
        :excluded -> acc
      end
    end)
  end

  defp apply_defaults_to_model(model, defaults) do
    case Map.get(model, :pricing) do
      nil -> Map.put(model, :pricing, defaults)
      pricing -> Map.put(model, :pricing, merge_pricing(defaults, pricing))
    end
  end

  defp apply_cost_components_to_model(model) do
    cost = Map.get(model, :cost) || Map.get(model, "cost")

    if is_map(cost) and map_size(cost) > 0 do
      pricing = Map.get(model, :pricing) || Map.get(model, "pricing") || %{}
      existing_components = components_list(pricing)
      cost_components = cost_components(cost)
      merged_components = Merge.merge_list_by_id(cost_components, existing_components)

      currency =
        Map.get(pricing, :currency) || Map.get(pricing, "currency") || "USD"

      updated_pricing =
        pricing
        |> Map.put(:currency, currency)
        |> Map.put(:components, merged_components)

      Map.put(model, :pricing, updated_pricing)
    else
      model
    end
  end

  defp merge_pricing(defaults, pricing) do
    case merge_mode(pricing) do
      "replace" -> pricing
      _ -> merge_by_id(defaults, pricing)
    end
  end

  defp merge_mode(pricing) do
    mode = Map.get(pricing, :merge) || Map.get(pricing, "merge")

    case mode do
      :replace -> "replace"
      "replace" -> "replace"
      :merge_by_id -> "merge_by_id"
      "merge_by_id" -> "merge_by_id"
      _ -> "merge_by_id"
    end
  end

  defp merge_by_id(defaults, pricing) do
    currency =
      Map.get(pricing, :currency) ||
        Map.get(pricing, "currency") ||
        Map.get(defaults, :currency) ||
        Map.get(defaults, "currency")

    default_components = components_list(defaults)
    pricing_components = components_list(pricing)
    merged_components = Merge.merge_list_by_id(default_components, pricing_components)

    pricing
    |> Map.put(:currency, currency)
    |> Map.put(:components, merged_components)
  end

  defp components_list(pricing) when is_map(pricing) do
    Map.get(pricing, :components) || Map.get(pricing, "components") || []
  end

  defp components_list(_pricing), do: []

  defp component_status(component, context) do
    excludes_when = Map.get(component, :excludes_when) || Map.get(component, "excludes_when")
    applies_when = Map.get(component, :applies_when) || Map.get(component, "applies_when")

    application = conditions_status(applies_when, context, :application)
    exclusion = conditions_status(excludes_when, context, :exclusion)

    case {application, exclusion} do
      {:no_match, _} -> :excluded
      {_, :match} -> :excluded
      {:match, :no_match} -> :applies
      _ -> :unresolved
    end
  end

  defp conditions_status(nil, _context, :application), do: :match
  defp conditions_status(nil, _context, :exclusion), do: :no_match
  defp conditions_status(conditions, _context, :application) when conditions == %{}, do: :match
  defp conditions_status(conditions, _context, :exclusion) when conditions == %{}, do: :no_match

  defp conditions_status(conditions, context, _mode) when is_map(conditions) do
    conditions
    |> Enum.map(fn {key, expected} -> condition_status(key, expected, context) end)
    |> merge_condition_statuses()
  end

  defp conditions_status(_conditions, _context, _mode), do: :unknown

  defp condition_status(key, expected, context) do
    case fetch_context(context, key) do
      {:ok, actual} -> expected_status(expected, actual)
      :error -> :unknown
    end
  end

  defp expected_status(_expected, nil), do: :unknown

  defp expected_status(expected, actual) when is_map(expected) and is_map(actual) do
    if comparison_map?(expected) do
      comparison_status(expected, actual)
    else
      expected
      |> Enum.map(fn {key, nested_expected} -> condition_status(key, nested_expected, actual) end)
      |> merge_condition_statuses()
    end
  end

  defp expected_status(expected, actual) when is_map(expected) do
    if comparison_map?(expected) do
      comparison_status(expected, actual)
    else
      :no_match
    end
  end

  defp expected_status(true, actual), do: truthy_status(actual)
  defp expected_status(expected, actual), do: if(expected == actual, do: :match, else: :no_match)

  defp comparison_map?(map) when is_map(map) do
    map
    |> Map.keys()
    |> Enum.any?(&(&1 in [:gt, "gt", :gte, "gte", :lt, "lt", :lte, "lte"]))
  end

  defp comparison_status(comparisons, actual) when is_number(actual) do
    comparisons
    |> Enum.map(fn
      {key, expected} when key in [:gt, "gt"] and is_number(expected) -> actual > expected
      {key, expected} when key in [:gte, "gte"] and is_number(expected) -> actual >= expected
      {key, expected} when key in [:lt, "lt"] and is_number(expected) -> actual < expected
      {key, expected} when key in [:lte, "lte"] and is_number(expected) -> actual <= expected
      _other -> :unknown
    end)
    |> bools_to_status()
  end

  defp comparison_status(_comparisons, _actual), do: :unknown

  defp truthy_status(false), do: :no_match
  defp truthy_status(_actual), do: :match

  defp merge_condition_statuses(statuses) do
    cond do
      Enum.any?(statuses, &(&1 == :no_match)) -> :no_match
      Enum.any?(statuses, &(&1 == :unknown)) -> :unknown
      true -> :match
    end
  end

  defp bools_to_status(results) do
    cond do
      Enum.any?(results, &(&1 == false)) -> :no_match
      Enum.any?(results, &(&1 == :unknown)) -> :unknown
      true -> :match
    end
  end

  defp fetch_context(context, key) do
    cond do
      Map.has_key?(context, key) ->
        {:ok, Map.get(context, key)}

      is_atom(key) and Map.has_key?(context, Atom.to_string(key)) ->
        {:ok, Map.get(context, Atom.to_string(key))}

      is_binary(key) ->
        atom_key = existing_atom(key)

        if not is_nil(atom_key) and Map.has_key?(context, atom_key) do
          {:ok, Map.get(context, atom_key)}
        else
          :error
        end

      true ->
        :error
    end
  end

  defp existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp context_map(context) when is_list(context), do: Map.new(context)
  defp context_map(context) when is_map(context), do: context
  defp context_map(_context), do: %{}

  defp cost_components(cost) when is_map(cost) do
    []
    |> maybe_add_token_component("token.input", Map.get(cost, :input) || Map.get(cost, "input"))
    |> maybe_add_token_component(
      "token.output",
      Map.get(cost, :output) || Map.get(cost, "output")
    )
    |> maybe_add_token_component(
      "token.cache_read",
      Map.get(cost, :cache_read) || Map.get(cost, "cache_read") ||
        Map.get(cost, :cached_input) || Map.get(cost, "cached_input")
    )
    |> maybe_add_token_component(
      "token.cache_write",
      Map.get(cost, :cache_write) || Map.get(cost, "cache_write")
    )
    |> maybe_add_token_component(
      "token.reasoning",
      Map.get(cost, :reasoning) || Map.get(cost, "reasoning")
    )
  end

  defp maybe_add_token_component(components, _id, nil), do: components

  defp maybe_add_token_component(components, id, rate) when is_number(rate) do
    components ++ [%{id: id, kind: "token", unit: "token", per: 1_000_000, rate: rate}]
  end

  defp maybe_add_token_component(components, _id, _rate), do: components
end
