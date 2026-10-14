defmodule LLMDB.Sources.Meta do
  @moduledoc """
  Cached source for the Meta Model API registry.

  `pull/1` requests `GET https://api.meta.ai/v1/models` with a bearer token.
  Set `META_API_KEY` or pass `:api_key`. Tests can pass `:req_opts` and
  `:cache_dir`. `:url` overrides the registry URL.

  `load/1` reads the cache without a network request or an API key. The default
  cache directory is `priv/llm_db/remote`; configure `:meta_cache_dir` to change it.

  The registry is specific to a team. A pull keeps previously discovered models
  when the response omits them. It preserves registry IDs, creation timestamps,
  and owners. It does not infer prices, limits, capabilities, or release dates.
  New registry entries stay catalog-only until a reviewed overlay supplies an
  execution contract. Muse Code and Muse Wonder Full are excluded.

  Missing credentials return `{:error, :no_api_key}`. Failed requests return a
  safe error and preserve the cache. HTTP errors retain their status code;
  transport errors and invalid responses do not include response data or keys.
  """

  @behaviour LLMDB.Source

  alias LLMDB.Sources.Remote

  @default_url "https://api.meta.ai/v1/models"
  @default_cache_dir "priv/llm_db/remote"
  @registry_fields ~w(id object created owned_by)

  @impl true
  def pull(opts) do
    case Map.get(opts, :api_key) || System.get_env("META_API_KEY") do
      key when is_binary(key) and key != "" -> pull_authenticated(opts, key)
      _missing -> {:error, :no_api_key}
    end
  end

  defp pull_authenticated(opts, key) do
    url = Map.get(opts, :url, @default_url)
    req_opts = Map.get(opts, :req_opts, [])

    headers =
      req_opts
      |> Keyword.get(:headers, [])
      |> Enum.reject(fn {name, _value} -> String.downcase(to_string(name)) == "authorization" end)

    req_opts = Keyword.put(req_opts, :headers, [{"authorization", "Bearer " <> key} | headers])

    case Remote.request_json(url, req_opts) do
      {:ok, response} ->
        with :ok <- validate_response(response) do
          Remote.store(url, merge_registry_cache(url, response, opts), cache_opts(opts))
        end

      {:error, {:http_status, status}} ->
        {:error, {:http_status, status}}

      {:error, {:json_error, _reason}} ->
        {:error, :invalid_response}

      {:error, _reason} ->
        {:error, :request_failed}
    end
  end

  @impl true
  def load(opts) do
    url = Map.get(opts, :url, @default_url)

    with {:ok, response} <- Remote.load(url, cache_opts(opts)),
         :ok <- validate_response(response) do
      {:ok, transform(response)}
    end
  end

  @doc "Converts registry records to sparse catalog entries under provider `:meta`."
  def transform(%{"data" => models}) when is_list(models) do
    models =
      models
      |> Enum.reject(&excluded_model?/1)
      |> Enum.map(fn model ->
        %{
          id: model["id"],
          provider: :meta,
          catalog_only: true,
          extra: %{created: model["created"], owned_by: model["owned_by"]}
        }
      end)

    %{"meta" => %{id: :meta, name: "Meta", models: models}}
  end

  defp validate_response(%{"data" => models}) when is_list(models) do
    if Enum.all?(models, &valid_model?/1), do: :ok, else: {:error, :invalid_response}
  end

  defp validate_response(_response), do: {:error, :invalid_response}

  defp valid_model?(%{"id" => id, "created" => created, "owned_by" => owner}),
    do: is_binary(id) and id != "" and is_integer(created) and created >= 0 and is_binary(owner)

  defp valid_model?(_model), do: false

  defp merge_registry_cache(url, response, opts) do
    previous =
      case Remote.load(url, cache_opts(opts)) do
        {:ok, cached} -> if validate_response(cached) == :ok, do: cached["data"], else: []
        {:error, _reason} -> []
      end

    models =
      (previous ++ response["data"])
      |> Enum.reject(&excluded_model?/1)
      |> Map.new(&{&1["id"], Map.take(&1, @registry_fields)})
      |> Map.values()
      |> Enum.sort_by(& &1["id"])

    %{"object" => "list", "data" => models}
  end

  defp excluded_model?(%{"id" => id}) do
    id == "muse-code" or String.starts_with?(id, "muse-code-") or
      String.starts_with?(id, "muse-wonder-full")
  end

  defp cache_opts(opts) do
    [
      cache_dir:
        Map.get(opts, :cache_dir) ||
          Application.get_env(:llm_db, :meta_cache_dir, @default_cache_dir),
      cache_key: "meta"
    ]
  end
end
