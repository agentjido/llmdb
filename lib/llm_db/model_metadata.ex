defmodule LLMDB.ModelMetadata do
  @moduledoc false

  alias LLMDB.{Loader, Model, Spec}
  alias LLMDB.Generated.ProviderRegistry

  @origin "https://llmcatalog.dev/api/v1/models"
  @max_bytes 65_536
  @fields ~w(id provider name release_date last_updated knowledge limits cost pricing
             modalities capabilities tags deprecated retired lifecycle catalog_only aliases)

  def fetch(spec, opts) do
    timeout = Keyword.get(opts, :timeout, 5_000)

    with true <- is_integer(timeout) and timeout in 1..30_000,
         {:ok, {provider, id}} <- Spec.parse_spec(spec),
         {:ok, ^provider} <- ProviderRegistry.fetch(Atom.to_string(provider)),
         {:ok, path} <- encode_path(id),
         {:ok, body} <- request("#{@origin}/#{provider}/#{path}", timeout, opts[:plug]) do
      decode(body, Atom.to_string(provider), id)
    else
      false -> {:error, :invalid_timeout}
      :error -> {:error, :unknown_provider}
      error -> error
    end
  end

  defp encode_path(id) do
    parts = String.split(id, "/")

    if byte_size(id) in 1..512 and Enum.all?(parts, &(&1 not in ["", ".", ".."])) do
      {:ok, Enum.map_join(parts, "/", &URI.encode(&1, fn char -> URI.char_unreserved?(char) end))}
    else
      {:error, :invalid_model_id}
    end
  end

  defp request(url, timeout, plug) do
    deadline = System.monotonic_time(:millisecond) + timeout

    options = [
      retry: false,
      redirect: false,
      raw: true,
      compressed: false,
      connect_options: [timeout: timeout],
      finch: [pool_timeout: timeout],
      receive_timeout: timeout,
      headers: [accept: "application/json"],
      into: fn {:data, chunk}, {request, response} ->
        receive_chunk(request, response, chunk, deadline)
      end
    ]

    options = if plug, do: Keyword.put(options, :plug, plug), else: options

    case Req.get(url, options) do
      {:ok, %{body: :timeout}} ->
        {:error, :timeout}

      {:ok, %{body: :response_too_large}} ->
        {:error, :response_too_large}

      {:ok, %{status: 200, body: body}} when is_binary(body) and byte_size(body) <= @max_bytes ->
        {:ok, body}

      {:ok, %{status: 200}} ->
        {:error, :response_too_large}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp receive_chunk(request, response, chunk, deadline) do
    current = response.body || ""

    cond do
      System.monotonic_time(:millisecond) > deadline ->
        {:halt, {request, %{response | body: :timeout}}}

      byte_size(current) + byte_size(chunk) > @max_bytes ->
        {:halt, {request, %{response | body: :response_too_large}}}

      true ->
        {:cont, {request, %{response | body: current <> chunk}}}
    end
  end

  defp decode(body, provider, id) do
    with {:ok,
          %{
            "schema_version" => 1,
            "snapshot_id" => snapshot_id,
            "model" => %{"provider" => ^provider, "id" => ^id} = model
          }} <- Jason.decode(body),
         true <- is_binary(snapshot_id) and Regex.match?(~r/\A[0-9a-f]{64}\z/, snapshot_id),
         {:ok, attrs} <- Loader.normalize_metadata_model(Map.take(model, @fields)),
         {:ok, %Model{} = validated} <- Model.new(attrs) do
      {:ok, validated}
    else
      _ -> {:error, :invalid_model_metadata}
    end
  end
end
