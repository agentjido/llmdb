defmodule LLMDB.Generated.ProviderRegistry.Source do
  @moduledoc false

  @provider_id_regex ~r/^[a-z0-9][a-z0-9_:-]{0,63}$/
  @max_providers 1_024

  @spec load!(String.t()) :: [{String.t(), atom()}]
  def load!(snapshot_path) when is_binary(snapshot_path) do
    providers =
      snapshot_path
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("providers")

    unless is_map(providers) do
      raise ArgumentError,
            "trusted provider registry input must contain a providers object: #{snapshot_path}"
    end

    if map_size(providers) > @max_providers do
      raise ArgumentError,
            "trusted provider registry input exceeds the #{@max_providers}-provider limit"
    end

    providers
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(fn provider_id ->
      unless is_binary(provider_id) and Regex.match?(@provider_id_regex, provider_id) do
        raise ArgumentError,
              "invalid provider ID in trusted provider registry input: #{inspect(provider_id)}"
      end

      {provider_id, String.to_atom(provider_id)}
    end)
  end
end

defmodule LLMDB.Generated.ProviderRegistry do
  @moduledoc false

  alias LLMDB.Generated.ProviderRegistry.Source

  @snapshot_path Path.expand("../../../priv/llm_db/snapshot.json", __DIR__)
  @external_resource @snapshot_path

  # Provider atoms are created while compiling the trusted package artifact,
  # never from a runtime snapshot. This preserves the atom-based public API
  # without allowing untrusted JSON to grow the VM atom table. Compilation
  # fails closed if the package artifact is absent or malformed so a final
  # build cannot silently ship an empty registry.
  @providers Source.load!(@snapshot_path)

  @providers_by_name Map.new(@providers)

  @spec fetch(String.t()) :: {:ok, atom()} | :error
  def fetch(provider_id) when is_binary(provider_id) do
    Map.fetch(@providers_by_name, provider_id)
  end

  @spec list() :: [atom()]
  def list, do: Enum.map(@providers, &elem(&1, 1))
end
