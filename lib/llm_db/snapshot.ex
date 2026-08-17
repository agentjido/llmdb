defmodule LLMDB.Snapshot do
  @moduledoc """
  Canonical snapshot artifact helpers.

  Snapshots are the immutable unit of metadata publication and runtime loading.
  They are stored as a single `snapshot.json` file, addressed by `snapshot_id`,
  and optionally mirrored to GitHub Releases.
  """

  alias LLMDB.Snapshot.Sparse

  @schema_version 1
  @sparse_schema_version 2
  @default_packaged_path "priv/llm_db/snapshot.json"
  @default_build_dir Path.join(["_build", "llm_db", "snapshot"])
  @snapshot_filename "snapshot.json"
  @snapshot_meta_filename "snapshot-meta.json"
  @latest_filename "latest.json"
  @snapshot_index_filename "snapshot-index.json"
  @history_meta_filename "history-meta.json"
  @history_archive_filename "history.tar.gz"
  @history_state_filename "state.json"

  @hash_excluded_keys MapSet.new([
                        "snapshot_id",
                        "generated_at",
                        "captured_at",
                        "published_at",
                        "parent_snapshot_id",
                        "provider_count",
                        "model_count",
                        "tag",
                        "snapshot_url",
                        "snapshot_meta_url",
                        "history_url"
                      ])

  @provider_id_regex ~r/^[a-z0-9][a-z0-9_:-]{0,63}$/

  require Logger

  @type integrity_policy :: :strict | :warn | :off

  @doc """
  Returns the canonical snapshot schema version.
  """
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc """
  Returns the opt-in sparse snapshot schema version.

  Sparse snapshots are readable in this release, but the packaged and published
  default remains schema v1 for backwards compatibility.
  """
  @spec sparse_schema_version() :: pos_integer()
  def sparse_schema_version, do: @sparse_schema_version

  @doc """
  Returns every snapshot schema version accepted by the reader.
  """
  @spec supported_schema_versions() :: [pos_integer()]
  def supported_schema_versions, do: [@schema_version, @sparse_schema_version]

  @doc """
  Returns the packaged snapshot file path.
  """
  @spec packaged_path() :: String.t()
  def packaged_path do
    case Application.get_env(:llm_db, :snapshot_path) do
      nil -> Application.app_dir(:llm_db, @default_packaged_path)
      path -> expand_path(path)
    end
  end

  @doc """
  Returns the source-tree packaged snapshot path used for release packaging.
  """
  @spec source_packaged_path() :: String.t()
  def source_packaged_path do
    Path.expand(@default_packaged_path)
  end

  @doc """
  Returns the local build output directory for snapshots.
  """
  @spec build_dir() :: String.t()
  def build_dir do
    Application.get_env(:llm_db, :snapshot_build_dir, @default_build_dir)
    |> expand_path()
  end

  @doc """
  Returns the default build artifact path for `snapshot.json`.
  """
  @spec build_path() :: String.t()
  def build_path, do: Path.join(build_dir(), @snapshot_filename)

  @doc """
  Returns the default build artifact path for `snapshot-meta.json`.
  """
  @spec build_meta_path() :: String.t()
  def build_meta_path, do: Path.join(build_dir(), @snapshot_meta_filename)

  @spec snapshot_filename() :: String.t()
  def snapshot_filename, do: @snapshot_filename

  @spec snapshot_meta_filename() :: String.t()
  def snapshot_meta_filename, do: @snapshot_meta_filename

  @spec latest_filename() :: String.t()
  def latest_filename, do: @latest_filename

  @spec snapshot_index_filename() :: String.t()
  def snapshot_index_filename, do: @snapshot_index_filename

  @spec history_meta_filename() :: String.t()
  def history_meta_filename, do: @history_meta_filename

  @spec history_archive_filename() :: String.t()
  def history_archive_filename, do: @history_archive_filename

  @spec history_state_filename() :: String.t()
  def history_state_filename, do: @history_state_filename

  @doc """
  Builds a canonical snapshot document from an engine snapshot.
  """
  @spec from_engine_snapshot(map(), keyword()) :: map()
  def from_engine_snapshot(
        %{version: version, generated_at: generated_at, providers: providers},
        opts \\ []
      ) do
    snapshot = %{
      "schema_version" => @schema_version,
      "version" => version,
      "generated_at" => generated_at,
      "providers" => json_safe(providers)
    }

    snapshot = Map.put(snapshot, "snapshot_id", snapshot_id(snapshot))

    case Keyword.get(opts, :schema_version, @schema_version) do
      @schema_version -> snapshot
      @sparse_schema_version -> to_sparse(snapshot)
      version -> raise ArgumentError, "unsupported snapshot schema version: #{inspect(version)}"
    end
  end

  @doc """
  Converts a canonical v1 snapshot to the deterministic sparse v2 wire shape.

  Only schema-known provider/model nulls and defaults are omitted. Unknown keys,
  nested `extra` data, explicit values, and array order are preserved. The
  content-addressed snapshot ID is recalculated for the v2 representation.
  """
  @spec to_sparse(map()) :: map()
  def to_sparse(snapshot) when is_map(snapshot) do
    sparse =
      snapshot
      |> json_safe()
      |> Map.put("schema_version", @sparse_schema_version)
      |> Map.delete("snapshot_id")
      |> Sparse.encode()

    Map.put(sparse, "snapshot_id", snapshot_id(sparse))
  end

  @doc """
  Computes the content-addressed snapshot ID for a snapshot document.
  """
  @spec snapshot_id(map()) :: String.t()
  def snapshot_id(snapshot) when is_map(snapshot) do
    snapshot
    |> hash_payload()
    |> canonical_digest_term()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Returns provider/model counts for a snapshot document.
  """
  @spec counts(map()) :: %{provider_count: non_neg_integer(), model_count: non_neg_integer()}
  def counts(snapshot) when is_map(snapshot) do
    providers = provider_map(snapshot)

    model_count =
      providers
      |> Map.values()
      |> Enum.map(fn provider ->
        provider
        |> Map.get("models", %{})
        |> map_size()
      end)
      |> Enum.sum()

    %{provider_count: map_size(providers), model_count: model_count}
  end

  @doc """
  Builds snapshot metadata suitable for `snapshot-index.json` and `latest.json`.
  """
  @spec metadata(map(), map()) :: map()
  def metadata(snapshot, attrs \\ %{}) when is_map(snapshot) and is_map(attrs) do
    %{provider_count: provider_count, model_count: model_count} = counts(snapshot)

    attrs
    |> Enum.into(%{
      "schema_version" => @schema_version,
      "snapshot_schema_version" => snapshot["schema_version"] || snapshot[:schema_version],
      "snapshot_id" => snapshot["snapshot_id"] || snapshot_id(snapshot),
      "captured_at" => snapshot["generated_at"],
      "provider_count" => provider_count,
      "model_count" => model_count
    })
  end

  @doc """
  Encodes a snapshot or metadata document as deterministic compact JSON.

  Object keys are sorted recursively. Array order and every encoded value are
  preserved. Schema v2 documents are normalized to the sparse wire shape before
  encoding; schema v1 and non-snapshot metadata documents only lose
  insignificant JSON whitespace.
  """
  @spec encode(map()) :: String.t()
  def encode(document) when is_map(document) do
    document
    |> json_safe()
    |> wire_document()
    |> canonical_json_map()
    |> Jason.encode!()
  end

  @doc """
  Decodes, verifies, migrates, and validates a snapshot document from JSON.

  The optional `:integrity_policy` controls checksum mismatch handling. A
  snapshot ID detects accidental corruption or content mismatch; it does not
  authenticate the snapshot publisher.
  """
  @spec decode(binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def decode(content, opts \\ []) when is_binary(content) and is_list(opts) do
    with {:ok, snapshot} <- Jason.decode(content),
         {:ok, prepared} <- prepare(snapshot, opts) do
      {:ok, prepared}
    end
  end

  @doc """
  Reads, verifies, migrates, and validates a snapshot document from disk.
  """
  @spec read(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def read(path, opts \\ []) when is_binary(path) and is_list(opts) do
    with {:ok, content} <- File.read(path) do
      decode(content, opts)
    end
  end

  @doc false
  @spec prepare(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare(snapshot, opts \\ []) when is_map(snapshot) and is_list(opts) do
    policy = Keyword.get(opts, :integrity_policy, :strict)

    with :ok <- apply_integrity_policy(snapshot, policy),
         {:ok, migrated} <- migrate(snapshot),
         :ok <- validate_document(migrated) do
      {:ok, migrated}
    end
  end

  @doc """
  Writes a snapshot or metadata document to disk.
  """
  @spec write!(String.t(), map()) :: :ok
  def write!(path, document) when is_binary(path) and is_map(document) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(path, encode(document))
  end

  @doc """
  Verifies snapshot checksum consistency and document safety.

  Snapshot IDs detect corruption or mismatched content. They are not an
  authenticity or trust guarantee.
  """
  @spec verify(map()) :: :ok | {:error, term()}
  def verify(snapshot) when is_map(snapshot) do
    with :ok <- verify_snapshot_id(snapshot),
         {:ok, migrated} <- migrate(snapshot),
         :ok <- validate_document(migrated) do
      :ok
    end
  end

  defp verify_snapshot_id(snapshot) do
    embedded_id = snapshot["snapshot_id"] || snapshot[:snapshot_id]

    verify_snapshot_id(snapshot, embedded_id)
  end

  defp verify_snapshot_id(snapshot, embedded_id) when is_binary(embedded_id) do
    computed_id = snapshot_id(snapshot)

    if embedded_id == computed_id do
      :ok
    else
      {:error, {:snapshot_id_mismatch, expected: embedded_id, computed: computed_id}}
    end
  end

  defp verify_snapshot_id(_snapshot, _embedded_id), do: {:error, :missing_snapshot_id}

  defp apply_integrity_policy(snapshot, policy) when policy in [:strict, :warn, :off] do
    case verify_snapshot_id(snapshot) do
      :ok ->
        :ok

      {:error, reason} when policy == :strict ->
        {:error, reason}

      {:error, reason} when policy == :warn ->
        Logger.warning(
          "llm_db: snapshot checksum check failed: #{inspect(reason)}. " <>
            "Loading because integrity_policy is :warn. Snapshot IDs detect " <>
            "corruption or mismatch; they do not authenticate publishers."
        )

        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp apply_integrity_policy(_snapshot, policy),
    do: {:error, {:invalid_integrity_policy, policy}}

  defp migrate(snapshot) do
    case snapshot["schema_version"] || snapshot[:schema_version] do
      nil -> {:ok, snapshot}
      @schema_version -> {:ok, snapshot}
      @sparse_schema_version -> {:ok, Sparse.expand(snapshot)}
      version -> {:error, {:unsupported_schema_version, version}}
    end
  end

  defp validate_document(snapshot) do
    providers = snapshot["providers"] || snapshot[:providers]
    models = snapshot["models"] || snapshot[:models]
    version = snapshot["version"] || snapshot[:version]

    cond do
      version == 2 and is_map(providers) ->
        validate_provider_ids(providers)

      is_list(providers) and is_list(models) ->
        validate_legacy_provider_ids(providers)

      true ->
        {:error, :invalid_snapshot_format}
    end
  end

  defp validate_provider_ids(providers) when is_map(providers) do
    case Enum.find(providers, fn {provider_id, provider} ->
           provider_id_str = to_string(provider_id)
           provider_doc_id = is_map(provider) && (provider["id"] || provider[:id])

           not String.match?(provider_id_str, @provider_id_regex) or
             not is_binary(provider_doc_id) or provider_doc_id != provider_id_str
         end) do
      nil -> :ok
      {provider_id, _provider} -> {:error, {:invalid_provider_id, provider_id}}
    end
  end

  defp validate_legacy_provider_ids(providers) do
    case Enum.find(providers, fn provider ->
           provider_id = is_map(provider) && (provider["id"] || provider[:id])

           not is_binary(provider_id) or
             not String.match?(provider_id, @provider_id_regex)
         end) do
      nil -> :ok
      provider -> {:error, {:invalid_provider_id, provider_id(provider)}}
    end
  end

  defp provider_id(provider) when is_map(provider), do: provider["id"] || provider[:id]
  defp provider_id(_provider), do: nil

  defp provider_map(%{"providers" => providers}) when is_map(providers), do: providers
  defp provider_map(%{providers: providers}) when is_map(providers), do: providers
  defp provider_map(_snapshot), do: %{}

  defp hash_payload(snapshot) do
    snapshot
    |> json_safe()
    |> wire_document()
    |> Enum.reject(fn {key, _value} -> MapSet.member?(@hash_excluded_keys, key) end)
    |> Map.new()
  end

  defp wire_document(%{"schema_version" => @sparse_schema_version} = snapshot) do
    Sparse.encode(snapshot)
  end

  defp wire_document(snapshot), do: snapshot

  defp json_safe(%LLMDB.Provider{} = value) do
    value
    |> Map.from_struct()
    |> drop_empty_snapshot_fields(runtime: nil, catalog_only: false)
    |> json_safe()
  end

  defp json_safe(%LLMDB.Model{} = value) do
    value
    |> Map.from_struct()
    |> drop_empty_snapshot_fields(doc_url: nil, execution: nil, catalog_only: false)
    |> json_safe()
  end

  defp json_safe(%_{} = value) do
    value
    |> Map.from_struct()
    |> json_safe()
  end

  defp json_safe(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested_value} -> {normalize_key(key), json_safe(nested_value)} end)
    |> Map.new()
  end

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)

  defp json_safe(value) when is_atom(value) and value not in [true, false, nil],
    do: Atom.to_string(value)

  defp json_safe(value), do: value

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)

  defp canonical_json_map(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _nested} -> key end)
    |> Enum.map(fn {key, nested} -> {key, canonical_json_map(nested)} end)
    |> Jason.OrderedObject.new()
  end

  defp canonical_json_map(value) when is_list(value), do: Enum.map(value, &canonical_json_map/1)
  defp canonical_json_map(value), do: value

  defp canonical_digest_term(value) when is_map(value) do
    entries =
      value
      |> Enum.map(fn {key, nested} -> {key, canonical_digest_term(nested)} end)
      |> Enum.sort_by(fn {key, _nested} -> key end)

    {:map, entries}
  end

  defp canonical_digest_term(value) when is_list(value) do
    {:list, Enum.map(value, &canonical_digest_term/1)}
  end

  defp canonical_digest_term(value), do: value

  defp drop_empty_snapshot_fields(map, fields) when is_map(map) and is_list(fields) do
    Enum.reduce(fields, map, fn {key, empty_value}, acc ->
      if Map.get(acc, key) == empty_value do
        Map.delete(acc, key)
      else
        acc
      end
    end)
  end

  defp expand_path(path) when is_binary(path) do
    if Path.type(path) == :absolute do
      path
    else
      Path.expand(path)
    end
  end
end
