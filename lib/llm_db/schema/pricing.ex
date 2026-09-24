defmodule LLMDB.Schema.Pricing do
  @moduledoc false

  @component Zoi.object(%{
               id: Zoi.string(),
               role:
                 Zoi.enum([
                   "rate",
                   "derived_rate",
                   "modifier"
                 ])
                 |> Zoi.nullish(),
               kind:
                 Zoi.enum([
                   "token",
                   "tool",
                   "image",
                   "storage",
                   "request",
                   "other"
                 ])
                 |> Zoi.nullish(),
               unit:
                 Zoi.enum([
                   "token",
                   "call",
                   "query",
                   "session",
                   "gb_day",
                   "image",
                   "source",
                   "other"
                 ])
                 |> Zoi.nullish(),
               per: Zoi.integer() |> Zoi.min(1) |> Zoi.nullish(),
               rate: Zoi.number() |> Zoi.nullish(),
               meter: Zoi.string() |> Zoi.nullish(),
               tool: Zoi.union([Zoi.atom(), Zoi.string()]) |> Zoi.nullish(),
               size_class: Zoi.string() |> Zoi.nullish(),
               multiplier: Zoi.number() |> Zoi.nullish(),
               derives_from: Zoi.string() |> Zoi.nullish(),
               applies_to: Zoi.array(Zoi.string()) |> Zoi.nullish(),
               rate_group: Zoi.string() |> Zoi.nullish(),
               rate_group_policy:
                 Zoi.enum(["at_most_one", "exactly_one"])
                 |> Zoi.nullish(),
               applies_when: Zoi.map() |> Zoi.nullish(),
               excludes_when: Zoi.map() |> Zoi.nullish(),
               mode: Zoi.string() |> Zoi.nullish(),
               charge_scope: Zoi.string() |> Zoi.nullish(),
               source: Zoi.string() |> Zoi.nullish(),
               notes: Zoi.string() |> Zoi.nullish()
             })
             |> Zoi.refine({__MODULE__, :validate_declared_role, []})

  @base_fields %{
    currency: Zoi.string() |> Zoi.nullish(),
    components: Zoi.array(@component) |> Zoi.default([])
  }

  @doc false
  def schema(extra_fields \\ %{}) when is_map(extra_fields) do
    @base_fields
    |> Map.merge(extra_fields)
    |> Zoi.object()
  end

  @doc false
  def validate_declared_role(component, _opts) do
    case Map.get(component, :role) do
      nil ->
        :ok

      "rate" ->
        validate_role_fields(
          component,
          [:rate, :unit, :per],
          [:multiplier, :derives_from, :applies_to]
        )

      "derived_rate" ->
        validate_role_fields(
          component,
          [:multiplier, :derives_from, :unit, :per],
          [:rate, :applies_to]
        )

      "modifier" ->
        with :ok <-
               validate_role_fields(
                 component,
                 [:multiplier, :applies_to],
                 [:rate, :per, :meter, :derives_from, :rate_group, :rate_group_policy]
               ),
             true <- Map.get(component, :applies_to) != [] do
          :ok
        else
          false -> {:error, "modifier applies_to must not be empty"}
          {:error, _reason} = error -> error
        end
    end
    |> validate_rate_group_policy(component)
  end

  defp validate_role_fields(component, required, forbidden) do
    missing = Enum.reject(required, &present?(component, &1))
    invalid = Enum.filter(forbidden, &present?(component, &1))

    cond do
      missing != [] ->
        {:error, "#{component.role} requires #{join_fields(missing)}"}

      invalid != [] ->
        {:error, "#{component.role} does not allow #{join_fields(invalid)}"}

      negative?(component, :rate) ->
        {:error, "rate must be zero or greater"}

      negative?(component, :multiplier) ->
        {:error, "multiplier must be zero or greater"}

      true ->
        :ok
    end
  end

  defp validate_rate_group_policy(:ok, %{rate_group_policy: policy} = component)
       when not is_nil(policy) do
    if present?(component, :rate_group) do
      :ok
    else
      {:error, "rate_group_policy requires rate_group"}
    end
  end

  defp validate_rate_group_policy(result, _component), do: result

  defp present?(component, key), do: not is_nil(Map.get(component, key))

  defp negative?(component, key) do
    case Map.get(component, key) do
      value when is_number(value) -> value < 0
      _other -> false
    end
  end

  defp join_fields(fields), do: fields |> Enum.map_join(", ", &Atom.to_string/1)
end
