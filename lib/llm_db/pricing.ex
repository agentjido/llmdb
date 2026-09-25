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

  @comparison_operators ~w(gt gte lt lte)
  @rate_group_policies ~w(at_most_one exactly_one)
  @canonical_token_groups %{
    "input" => "input_tokens",
    "output" => "output_tokens",
    "cache_read" => "cache_read_tokens",
    "cache_write" => "cache_write_tokens",
    "reasoning" => "reasoning_tokens"
  }

  @type component_role :: :rate | :derived_rate | :modifier
  @type validation_error :: %{
          required(:code) => atom(),
          required(:message) => String.t(),
          optional(:component_id) => String.t() | nil,
          optional(atom()) => term()
        }

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
  generated components (merged by ID). Model-level `excluded_cost_components`
  suppresses specified legacy conversions without deleting explicit components
  or changing the legacy `cost` summary. This avoids counting included reasoning
  twice or interpreting subscription summaries as token-credit tariffs.

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

  @doc """
  Returns the declared or inferred role of a pricing component.

  The optional `role` field is authoritative. Components without it retain the
  legacy behavior: `rate`, `derives_from`, and `applies_to` identify direct
  rates, derived rates, and modifiers. A component with none or more than one
  of these signatures is invalid for strict selection.
  """
  @spec component_role(map()) ::
          {:ok, component_role()}
          | {:error,
             :missing_component_role | :ambiguous_component_role | :invalid_component_role}
  def component_role(component) when is_map(component) do
    case field(component, :role) do
      role when role in ["rate", :rate] -> {:ok, :rate}
      role when role in ["derived_rate", :derived_rate] -> {:ok, :derived_rate}
      role when role in ["modifier", :modifier] -> {:ok, :modifier}
      nil -> infer_component_role(component)
      _other -> {:error, :invalid_component_role}
    end
  end

  @doc """
  Validates component roles, conditions, IDs, and cross-component references.

  This validation is additive. Legacy components do not need a `role`; their
  role is inferred with `component_role/1`. The function does not change the
  components.
  """
  @spec validate_components([map()]) :: :ok | {:error, [validation_error()]}
  def validate_components(components) when is_list(components) do
    errors =
      components
      |> Enum.flat_map(&component_validation_errors/1)
      |> Kernel.++(duplicate_id_errors(components))
      |> Kernel.++(reference_errors(components))
      |> Kernel.++(dependency_cycle_errors(components))
      |> Kernel.++(rate_group_policy_errors(components))

    case errors do
      [] -> :ok
      _errors -> {:error, errors}
    end
  end

  @doc """
  Selects components and applies strict structural and selection checks.

  `components_for/2` remains the backward-compatible low-level selector.
  `select_components/2` returns `{:ok, result}` only when component validation
  succeeds, no condition is unresolved, and no rate group selects more than one
  rate. A group with `rate_group_policy: "exactly_one"` must select one rate.

  The result always contains `components`, `unresolved`, and `errors`.
  """
  @spec select_components(map(), map() | keyword()) ::
          {:ok, %{components: [map()], unresolved: [map()], errors: []}}
          | {:error, %{components: [map()], unresolved: [map()], errors: [validation_error()]}}
  def select_components(model, context \\ %{}) when is_map(model) do
    pricing = Map.get(model, :pricing, Map.get(model, "pricing", %{}))
    candidates = components_list(pricing)
    selection = components_for(model, context)

    validation_errors =
      case validate_components(candidates) do
        :ok -> []
        {:error, errors} -> errors
      end

    errors =
      case validation_errors do
        [] ->
          missing_pricing_errors(candidates) ++
            unresolved_selection_errors(selection.unresolved) ++
            selected_dependency_errors(selection.components) ++
            rate_selection_errors(candidates, selection.components)

        errors ->
          errors
      end

    result = Map.put(selection, :errors, errors)

    if errors == [] do
      {:ok, result}
    else
      {:error, result}
    end
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

      cost_components = cost_components(cost, pricing)
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

  defp infer_component_role(component) do
    signatures =
      [
        rate: present?(component, :rate),
        derived_rate: present?(component, :derives_from),
        modifier: present?(component, :applies_to)
      ]
      |> Enum.filter(fn {_role, present} -> present end)
      |> Enum.map(&elem(&1, 0))

    case signatures do
      [role] -> {:ok, role}
      [] -> {:error, :missing_component_role}
      _roles -> {:error, :ambiguous_component_role}
    end
  end

  defp component_validation_errors(component) do
    id_errors =
      if non_empty_string?(field(component, :id)) do
        []
      else
        [component_error(:invalid_component_id, component, "component id must be a string")]
      end

    role_errors =
      case component_role(component) do
        {:ok, role} ->
          role_shape_errors(component, role)

        {:error, :missing_component_role} ->
          [
            component_error(
              :missing_component_role,
              component,
              "component must declare role or contain exactly one role signature"
            )
          ]

        {:error, :ambiguous_component_role} ->
          [
            component_error(
              :ambiguous_component_role,
              component,
              "component contains fields from more than one role"
            )
          ]

        {:error, :invalid_component_role} ->
          [
            component_error(
              :invalid_component_role,
              component,
              "component role must be rate, derived_rate, or modifier"
            )
          ]
      end

    id_errors ++
      role_errors ++
      condition_errors(component, :applies_when) ++
      condition_errors(component, :excludes_when)
  end

  defp role_shape_errors(component, :rate) do
    required_field_errors(component, [
      {:rate, &non_negative_number?/1},
      {:unit, &non_empty_string?/1},
      {:per, &positive_integer?/1}
    ]) ++
      forbidden_field_errors(component, [:multiplier, :derives_from, :applies_to]) ++
      rate_group_field_errors(component)
  end

  defp role_shape_errors(component, :derived_rate) do
    required_field_errors(component, [
      {:multiplier, &non_negative_number?/1},
      {:derives_from, &non_empty_string?/1},
      {:unit, &non_empty_string?/1},
      {:per, &positive_integer?/1}
    ]) ++
      forbidden_field_errors(component, [:rate, :applies_to]) ++
      rate_group_field_errors(component)
  end

  defp role_shape_errors(component, :modifier) do
    required_field_errors(component, [
      {:multiplier, &non_negative_number?/1},
      {:applies_to, &non_empty_string_list?/1}
    ]) ++
      forbidden_field_errors(component, [
        :rate,
        :per,
        :meter,
        :derives_from,
        :rate_group,
        :rate_group_policy
      ])
  end

  defp required_field_errors(component, requirements) do
    Enum.flat_map(requirements, fn {key, valid?} ->
      if valid?.(field(component, key)) do
        []
      else
        [
          component_error(
            :invalid_role_field,
            component,
            "#{role_name(component)} requires a valid #{key}",
            %{field: key}
          )
        ]
      end
    end)
  end

  defp forbidden_field_errors(component, fields) do
    Enum.flat_map(fields, fn key ->
      if present?(component, key) do
        [
          component_error(
            :invalid_role_field,
            component,
            "#{role_name(component)} does not allow #{key}",
            %{field: key}
          )
        ]
      else
        []
      end
    end)
  end

  defp rate_group_field_errors(component) do
    group = field(component, :rate_group)
    policy = field(component, :rate_group_policy)

    cond do
      not is_nil(group) and not non_empty_string?(group) ->
        [
          component_error(
            :invalid_rate_group,
            component,
            "rate_group must be a non-empty string",
            %{field: :rate_group}
          )
        ]

      not is_nil(policy) and policy not in @rate_group_policies and
          policy not in [:at_most_one, :exactly_one] ->
        [
          component_error(
            :invalid_rate_group_policy,
            component,
            "rate_group_policy must be at_most_one or exactly_one",
            %{field: :rate_group_policy}
          )
        ]

      not is_nil(policy) and is_nil(group) ->
        [
          component_error(
            :missing_rate_group,
            component,
            "rate_group_policy requires rate_group",
            %{field: :rate_group}
          )
        ]

      true ->
        []
    end
  end

  defp condition_errors(component, field_name) do
    case field(component, field_name) do
      nil ->
        []

      conditions when is_map(conditions) ->
        Enum.flat_map(
          conditions,
          &nested_comparison_errors(component, field_name, [], &1)
        )

      _other ->
        [
          component_error(
            :invalid_conditions,
            component,
            "#{field_name} must be a map",
            %{field: field_name}
          )
        ]
    end
  end

  defp comparison_errors(component, field_name, path, conditions) do
    keys = Enum.map(Map.keys(conditions), &condition_key/1)
    comparison? = Enum.any?(keys, &(&1 in @comparison_operators))

    if comparison? do
      Enum.flat_map(conditions, fn {key, value} ->
        normalized = condition_key(key)

        cond do
          normalized not in @comparison_operators ->
            [
              component_error(
                :invalid_comparison_operator,
                component,
                "comparison map contains unsupported operator #{normalized}",
                %{field: field_name, path: path ++ [normalized]}
              )
            ]

          not is_number(value) ->
            [
              component_error(
                :invalid_comparison_value,
                component,
                "comparison operator #{normalized} requires a number",
                %{field: field_name, path: path ++ [normalized]}
              )
            ]

          true ->
            []
        end
      end)
    else
      Enum.flat_map(
        conditions,
        &nested_comparison_errors(component, field_name, path, &1)
      )
    end
  end

  defp nested_comparison_errors(component, field_name, path, {key, value})
       when is_map(value) do
    comparison_errors(component, field_name, path ++ [condition_key(key)], value)
  end

  defp nested_comparison_errors(_component, _field_name, _path, _condition), do: []

  defp duplicate_id_errors(components) do
    components
    |> Enum.group_by(&field(&1, :id))
    |> Enum.flat_map(fn
      {id, duplicates} when is_binary(id) and length(duplicates) > 1 ->
        [
          component_error(
            :duplicate_component_id,
            hd(duplicates),
            "component id #{id} is not unique",
            %{component_ids: List.duplicate(id, length(duplicates))}
          )
        ]

      _entry ->
        []
    end)
  end

  defp reference_errors(components) do
    by_id =
      components
      |> Enum.filter(&non_empty_string?(field(&1, :id)))
      |> Map.new(&{field(&1, :id), &1})

    Enum.flat_map(components, fn component ->
      derived_reference_errors(component, by_id) ++ modifier_reference_errors(component, by_id)
    end)
  end

  defp derived_reference_errors(component, by_id) do
    case component_role(component) do
      {:ok, :derived_rate} ->
        target_id = field(component, :derives_from)
        validate_derived_target(component, target_id, Map.get(by_id, target_id))

      _other ->
        []
    end
  end

  defp validate_derived_target(component, target_id, nil) do
    [
      component_error(
        :missing_derived_rate_target,
        component,
        "derives_from target #{inspect(target_id)} does not exist",
        %{target_id: target_id}
      )
    ]
  end

  defp validate_derived_target(component, target_id, target) do
    if component_role(target) in [{:ok, :rate}, {:ok, :derived_rate}] do
      []
    else
      [
        component_error(
          :invalid_derived_rate_target,
          component,
          "derives_from target #{inspect(target_id)} is not a rate",
          %{target_id: target_id}
        )
      ]
    end
  end

  defp modifier_reference_errors(component, by_id) do
    case component_role(component) do
      {:ok, :modifier} ->
        component
        |> field(:applies_to)
        |> List.wrap()
        |> Enum.flat_map(&modifier_target_errors(component, &1, by_id))

      _other ->
        []
    end
  end

  defp modifier_target_errors(component, pattern, by_id) when is_binary(pattern) do
    targets =
      by_id
      |> Enum.filter(fn {id, _target} -> component_pattern_matches?(pattern, id) end)
      |> Enum.map(&elem(&1, 1))

    cond do
      targets == [] ->
        [
          component_error(
            :missing_modifier_target,
            component,
            "applies_to target #{pattern} does not match a component",
            %{target_id: pattern}
          )
        ]

      Enum.any?(targets, fn target ->
        component_role(target) not in [{:ok, :rate}, {:ok, :derived_rate}]
      end) ->
        [
          component_error(
            :invalid_modifier_target,
            component,
            "applies_to target #{pattern} matches a non-rate component",
            %{target_id: pattern}
          )
        ]

      true ->
        []
    end
  end

  defp modifier_target_errors(component, pattern, _by_id) do
    [
      component_error(
        :invalid_modifier_target,
        component,
        "applies_to target must be a string",
        %{target_id: pattern}
      )
    ]
  end

  defp dependency_cycle_errors(components) do
    by_id =
      components
      |> Enum.filter(&non_empty_string?(field(&1, :id)))
      |> Map.new(&{field(&1, :id), &1})

    by_id
    |> Map.keys()
    |> Enum.map(&dependency_cycle(&1, by_id, []))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(fn cycle -> cycle |> Enum.drop(-1) |> Enum.sort() end)
    |> Enum.map(fn cycle ->
      component = Map.get(by_id, hd(cycle), %{})

      component_error(
        :derived_rate_cycle,
        component,
        "derived rate dependency cycle: #{Enum.join(cycle, " -> ")}",
        %{component_ids: cycle}
      )
    end)
  end

  defp dependency_cycle(id, by_id, path) do
    case Enum.find_index(path, &(&1 == id)) do
      nil -> follow_dependency(id, by_id, path)
      start -> Enum.drop(path, start) ++ [id]
    end
  end

  defp follow_dependency(id, by_id, path) do
    case field(Map.get(by_id, id, %{}), :derives_from) do
      target when is_binary(target) -> dependency_cycle(target, by_id, path ++ [id])
      _other -> nil
    end
  end

  defp rate_group_policy_errors(components) do
    components
    |> Enum.filter(fn component ->
      component_role(component) in [{:ok, :rate}, {:ok, :derived_rate}] and
        non_empty_string?(field(component, :rate_group))
    end)
    |> Enum.group_by(&field(&1, :rate_group))
    |> Enum.flat_map(fn {group, members} ->
      policies =
        members
        |> Enum.map(&normalize_rate_group_policy(field(&1, :rate_group_policy)))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      if length(policies) > 1 do
        [
          component_error(
            :conflicting_rate_group_policy,
            hd(members),
            "rate group #{group} has conflicting policies",
            %{rate_group: group, policies: policies}
          )
        ]
      else
        []
      end
    end)
  end

  defp missing_pricing_errors([]) do
    [
      %{
        code: :missing_pricing_components,
        message: "strict selection requires pricing components"
      }
    ]
  end

  defp missing_pricing_errors(components) do
    if Enum.any?(components, &(component_role(&1) in [{:ok, :rate}, {:ok, :derived_rate}])) do
      []
    else
      [
        %{
          code: :missing_rate_components,
          message: "strict selection requires at least one rate component"
        }
      ]
    end
  end

  defp unresolved_selection_errors([]), do: []

  defp unresolved_selection_errors(components) do
    ids = Enum.map(components, &field(&1, :id))

    [
      %{
        code: :unresolved_components,
        component_ids: ids,
        message: "selection requires more context for #{length(components)} component(s)"
      }
    ]
  end

  defp selected_dependency_errors(components) do
    selected_by_id =
      components
      |> Enum.filter(&non_empty_string?(field(&1, :id)))
      |> Map.new(&{field(&1, :id), &1})

    Enum.flat_map(components, fn component ->
      case component_role(component) do
        {:ok, :derived_rate} ->
          target_id = field(component, :derives_from)

          if Map.has_key?(selected_by_id, target_id) do
            []
          else
            [
              component_error(
                :unselected_derived_rate_target,
                component,
                "selected derived rate requires selected target #{inspect(target_id)}",
                %{target_id: target_id}
              )
            ]
          end

        _other ->
          []
      end
    end)
  end

  defp rate_selection_errors(candidates, selected) do
    candidate_groups = rate_groups(candidates)
    selected_groups = rate_groups(selected)

    Enum.flat_map(candidate_groups, fn {group, group_candidates} ->
      selected_rates = Map.get(selected_groups, group, [])
      policy = group_policy(group_candidates)

      cond do
        length(selected_rates) > 1 ->
          [
            %{
              code: :multiple_rates_for_group,
              rate_group: group,
              component_ids: Enum.map(selected_rates, &field(&1, :id)),
              message: "rate group #{group} selected more than one rate"
            }
          ]

        policy == "exactly_one" and selected_rates == [] ->
          [
            %{
              code: :missing_rate_for_group,
              rate_group: group,
              component_ids: Enum.map(group_candidates, &field(&1, :id)),
              message: "rate group #{group} must select exactly one rate"
            }
          ]

        true ->
          []
      end
    end)
  end

  defp rate_groups(components) do
    components
    |> Enum.filter(&(component_role(&1) in [{:ok, :rate}, {:ok, :derived_rate}]))
    |> Enum.group_by(&rate_group/1)
  end

  defp rate_group(component) do
    field(component, :rate_group) ||
      field(component, :meter) ||
      canonical_token_group(field(component, :id)) ||
      field(component, :id)
  end

  defp canonical_token_group("token." <> rest) do
    case String.split(rest, ".", parts: 2) do
      [meter | _rest] -> Map.get(@canonical_token_groups, meter, "token.#{meter}")
      _other -> nil
    end
  end

  defp canonical_token_group(_id), do: nil

  defp group_policy(components) do
    components
    |> Enum.map(&normalize_rate_group_policy(field(&1, :rate_group_policy)))
    |> Enum.find(&(&1 == "exactly_one"))
  end

  defp normalize_rate_group_policy(:at_most_one), do: "at_most_one"
  defp normalize_rate_group_policy(:exactly_one), do: "exactly_one"
  defp normalize_rate_group_policy(policy) when policy in @rate_group_policies, do: policy
  defp normalize_rate_group_policy(_policy), do: nil

  defp component_pattern_matches?(pattern, id) do
    if String.ends_with?(pattern, ".*") do
      prefix = String.trim_trailing(pattern, "*")
      String.starts_with?(id, prefix)
    else
      pattern == id
    end
  end

  defp role_name(component) do
    case component_role(component) do
      {:ok, role} -> role
      _other -> :component
    end
  end

  defp component_error(code, component, message, extra \\ %{}) do
    Map.merge(
      %{code: code, component_id: field(component, :id), message: message},
      extra
    )
  end

  defp condition_key(key) when is_atom(key), do: Atom.to_string(key)
  defp condition_key(key) when is_binary(key), do: key
  defp condition_key(key), do: inspect(key)

  defp present?(component, key), do: not is_nil(field(component, key))

  defp field(component, key) when is_map(component) and is_atom(key) do
    case Map.fetch(component, key) do
      {:ok, value} -> value
      :error -> Map.get(component, Atom.to_string(key))
    end
  end

  defp non_empty_string?(value), do: is_binary(value) and value != ""
  defp non_negative_number?(value), do: is_number(value) and value >= 0
  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp non_empty_string_list?(value) do
    is_list(value) and value != [] and Enum.all?(value, &non_empty_string?/1)
  end

  defp cost_components(cost, pricing) do
    excluded =
      Map.get(pricing, :excluded_cost_components) ||
        Map.get(pricing, "excluded_cost_components") || []

    Enum.reject(cost_components(cost), &(&1.id in excluded))
  end

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
