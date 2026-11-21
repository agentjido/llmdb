defmodule LLMDB.Enrich.Flex do
  @moduledoc false

  @path [:experimental, "modes", "flex"]

  def enrich_models(providers, models) do
    policies =
      for %{id: id, extra: %{experimental: %{"modes" => %{"flex" => %{"models" => _} = policy}}}} <-
            providers,
          into: %{} do
        {id, policy}
      end

    Enum.map(models, fn model ->
      case model_mode(policies[model.provider], model.id) do
        nil -> model
        mode -> %{model | extra: put_default(model.extra || %{}, @path, mode)}
      end
    end)
  end

  defp model_mode(%{"models" => "all"} = policy, _id), do: Map.delete(policy, "models")

  defp model_mode(%{"models" => ids} = policy, id) when is_list(ids) do
    if id in ids, do: Map.delete(policy, "models")
  end

  defp model_mode(%{"models" => versions} = policy, id) when is_map(versions) do
    case Map.fetch(versions, id) do
      {:ok, version} ->
        policy
        |> Map.delete("models")
        |> Map.update(
          "constraints",
          %{"model_version" => version},
          &Map.put(&1, "model_version", version)
        )

      :error ->
        nil
    end
  end

  defp model_mode(_policy, _id), do: nil

  defp put_default(map, [key], value) when is_map(map) do
    Map.update(map, key, value, &merge_policy_defaults(&1, value))
  end

  defp put_default(map, [key | rest], value) when is_map(map) do
    Map.update(map, key, put_default(%{}, rest, value), fn child ->
      put_default(child, rest, value)
    end)
  end

  defp put_default(value, _path, _default), do: value

  # Cached rates can supply a Flex entry without declaring eligibility.
  defp merge_policy_defaults(%{"supported" => _} = mode, _defaults), do: mode
  defp merge_policy_defaults(mode, defaults) when is_map(mode), do: Map.merge(defaults, mode)
  defp merge_policy_defaults(mode, _defaults), do: mode
end
