defmodule LLMDB.Engine.LifecyclePolicy do
  @moduledoc false

  def read(nil), do: {:ok, MapSet.new()}

  def read(path) do
    with {:ok, %{"families" => families}} when is_map(families) <- Toml.decode_file(path),
         {:ok, offers} <- collect(families) do
      {:ok, MapSet.new(offers)}
    else
      error -> {:error, {:invalid_lifecycle_policy, path, error}}
    end
  end

  def apply(models, offers) do
    Enum.map(models, fn model ->
      key = {Atom.to_string(model.provider), model.id}

      if MapSet.member?(offers, key) and model.retired != true do
        lifecycle = Map.put(model.lifecycle || %{}, :status, "deprecated")
        %{model | lifecycle: lifecycle, deprecated: true}
      else
        model
      end
    end)
  end

  defp collect(families) do
    entries =
      Enum.flat_map(families, fn
        {_family, providers} when is_map(providers) -> Map.to_list(providers)
        entry -> [entry]
      end)

    if Enum.all?(entries, fn
         {provider, ids} when is_binary(provider) and is_list(ids) ->
           ids != [] and Enum.all?(ids, &(is_binary(&1) and &1 != ""))

         _ ->
           false
       end) do
      {:ok, for({provider, ids} <- entries, id <- ids, do: {provider, id})}
    else
      {:error, :invalid_provider_models}
    end
  end
end
