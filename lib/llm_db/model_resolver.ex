defmodule LLMDB.ModelResolver do
  @moduledoc false

  alias LLMDB.ModelResolver.Defaults

  @type resolution :: {atom(), String.t(), map()}
  @type mode :: :canonical | :alias
  @type lookup :: (String.t(), mode() -> resolution() | nil)
  @type prefix_rules :: %{atom() => [String.t()]}

  @spec prefix_rules([map()]) :: prefix_rules()
  def prefix_rules(providers) do
    Enum.reduce(providers, Defaults.prefix_rules(), fn provider, rules ->
      extra = field(provider, :extra) || %{}

      case field(extra, :model_id_prefixes) do
        prefixes when is_list(prefixes) ->
          normalized =
            prefixes
            |> Enum.filter(&(is_binary(&1) and &1 != ""))
            |> Enum.uniq()
            |> Enum.sort_by(&{-byte_size(&1), &1})

          Map.put(rules, field(provider, :id), normalized)

        _other ->
          rules
      end
    end)
  end

  @spec resolve_model(String.t(), [String.t()], lookup()) ::
          {:ok, resolution()} | {:error, :not_found}
  def resolve_model(model_id, prefixes, lookup) do
    resolution =
      case strip_prefix(model_id, prefixes) do
        {_base_id, nil} ->
          lookup.(model_id, :alias)

        {base_id, prefix} ->
          match =
            lookup.(model_id, :canonical) || lookup.(model_id, :alias) ||
              lookup.(base_id, :alias)

          preserve_prefix(match, prefix, prefixes)
      end

    case resolution do
      nil -> {:error, :not_found}
      match -> {:ok, match}
    end
  end

  @spec resolve_bare(
          String.t(),
          [resolution()],
          prefix_rules(),
          (atom(), String.t(), mode() -> resolution() | nil)
        ) :: {:ok, resolution()} | {:error, :not_found | :ambiguous}
  def resolve_bare(model_id, direct, rules, lookup) do
    matches =
      Enum.reduce(rules, direct, fn {provider_id, prefixes}, matches ->
        case strip_prefix(model_id, prefixes) do
          {_base_id, nil} ->
            matches

          {_base_id, _prefix} ->
            others = Enum.reject(matches, fn {provider, _, _} -> provider == provider_id end)

            case resolve_model(model_id, prefixes, fn lookup_id, mode ->
                   lookup.(provider_id, lookup_id, mode)
                 end) do
              {:ok, resolution} -> others ++ [resolution]
              {:error, :not_found} -> others
            end
        end
      end)
      |> Enum.uniq_by(fn {provider, canonical_id, _model} -> {provider, canonical_id} end)

    case matches do
      [] -> {:error, :not_found}
      [match] -> {:ok, match}
      [_ | _] -> {:error, :ambiguous}
    end
  end

  @spec strip_prefix(String.t(), [String.t()]) :: {String.t(), String.t() | nil}
  def strip_prefix(model_id, prefixes) when is_binary(model_id) do
    Enum.find_value(prefixes, {model_id, nil}, fn prefix ->
      if String.starts_with?(model_id, prefix) do
        {String.replace_prefix(model_id, prefix, ""), prefix}
      end
    end)
  end

  defp preserve_prefix(nil, _prefix, _prefixes), do: nil

  defp preserve_prefix({provider, canonical_id, model}, prefix, prefixes) do
    returned_id =
      case strip_prefix(canonical_id, prefixes) do
        {_base_id, nil} -> prefix <> canonical_id
        {_base_id, _prefix} -> canonical_id
      end

    {provider, returned_id, model}
  end

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
