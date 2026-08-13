defmodule LLMDB.NPM.Exporter do
  @moduledoc false

  alias LLMDB.Snapshot

  @format_version 1
  @marker_filename ".llmdb-npm-export"
  @provider_filename ~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/

  @spec export!(String.t(), keyword()) :: map()
  def export!(output_dir, opts \\ []) when is_binary(output_dir) and is_list(opts) do
    source_path = Keyword.get(opts, :source, Snapshot.source_packaged_path())
    output_dir = safe_output_dir!(output_dir)

    snapshot =
      case Snapshot.read(source_path, integrity_policy: :strict) do
        {:ok, snapshot} -> snapshot
        {:error, reason} -> raise "could not read canonical snapshot: #{inspect(reason)}"
      end

    ensure_canonical_schema!(snapshot)

    providers = Map.fetch!(snapshot, "providers")
    provider_entries = Enum.sort_by(providers, fn {provider_id, _provider} -> provider_id end)
    staging_dir = unique_sibling_path(output_dir, "staging")

    validate_providers!(provider_entries)
    validate_output_dir!(output_dir)

    try do
      prepare_staging_dir!(staging_dir)
      providers_dir = Path.join(staging_dir, "providers")
      File.mkdir_p!(providers_dir)

      provider_summaries =
        Map.new(provider_entries, fn {provider_id, provider} ->
          write_provider!(providers_dir, provider_id, provider)
          {provider_id, provider_summary(provider)}
        end)

      model_count =
        provider_entries
        |> Enum.map(fn {_provider_id, provider} ->
          provider |> Map.fetch!("models") |> map_size()
        end)
        |> Enum.sum()

      manifest = %{
        "format_version" => @format_version,
        "snapshot_schema_version" => Map.fetch!(snapshot, "schema_version"),
        "catalog_version" => Map.fetch!(snapshot, "version"),
        "generated_at" => Map.fetch!(snapshot, "generated_at"),
        "snapshot_id" => Map.fetch!(snapshot, "snapshot_id"),
        "provider_count" => map_size(providers),
        "model_count" => model_count,
        "providers" => provider_summaries
      }

      Snapshot.write!(Path.join(staging_dir, "manifest.json"), manifest)
      verify_export!(staging_dir, snapshot, manifest)
      replace_output_dir!(staging_dir, output_dir)

      manifest
    after
      File.rm_rf(staging_dir)
    end
  end

  defp write_provider!(providers_dir, provider_id, provider) do
    Snapshot.write!(Path.join(providers_dir, "#{provider_id}.json"), provider)
  end

  defp validate_providers!(provider_entries) do
    Enum.each(provider_entries, fn {provider_id, provider} ->
      unless Regex.match?(@provider_filename, provider_id) do
        raise "provider ID is not safe for a cross-platform NPM subpath: " <>
                inspect(provider_id)
      end

      unless is_map(provider) and provider["id"] == provider_id and
               is_map(provider["models"]) do
        raise "provider is not valid for an NPM shard: #{inspect(provider_id)}"
      end
    end)
  end

  defp provider_summary(provider) do
    %{
      "id" => Map.fetch!(provider, "id"),
      "name" => Map.get(provider, "name"),
      "base_url" => Map.get(provider, "base_url"),
      "doc" => Map.get(provider, "doc"),
      "alias_of" => Map.get(provider, "alias_of"),
      "catalog_only" => Map.get(provider, "catalog_only", false),
      "model_count" => provider |> Map.fetch!("models") |> map_size()
    }
  end

  defp verify_export!(output_dir, snapshot, manifest) do
    exported_providers =
      manifest["providers"]
      |> Map.keys()
      |> Map.new(fn provider_id ->
        path = Path.join([output_dir, "providers", "#{provider_id}.json"])
        {provider_id, path |> File.read!() |> Jason.decode!()}
      end)

    reconstructed = Map.put(snapshot, "providers", exported_providers)

    unless reconstructed == snapshot do
      raise "NPM provider shards do not reconstruct the canonical snapshot"
    end

    case Snapshot.verify(reconstructed) do
      :ok ->
        :ok

      {:error, reason} ->
        raise "reconstructed NPM snapshot failed verification: #{inspect(reason)}"
    end
  end

  defp ensure_canonical_schema!(%{"schema_version" => 1}), do: :ok

  defp ensure_canonical_schema!(snapshot) do
    raise "NPM export requires canonical snapshot schema v1, got: " <>
            inspect(Map.get(snapshot, "schema_version"))
  end

  defp safe_output_dir!(output_dir) do
    expanded = Path.expand(output_dir)
    forbidden = [Path.expand("/"), Path.expand("."), System.user_home!()]

    if expanded in forbidden or Path.dirname(expanded) == expanded do
      raise ArgumentError, "unsafe NPM export directory: #{expanded}"
    end

    expanded
  end

  defp validate_output_dir!(output_dir) do
    case File.stat(output_dir) do
      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{type: :directory}} ->
        entries = File.ls!(output_dir)
        marker_path = Path.join(output_dir, @marker_filename)

        if entries != [] and not File.regular?(marker_path) do
          raise ArgumentError,
                "refusing to replace an NPM export directory without an ownership marker: " <>
                  output_dir
        end

      {:ok, _stat} ->
        raise ArgumentError, "NPM export path is not a directory: #{output_dir}"

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read NPM export directory", path: output_dir
    end
  end

  defp prepare_staging_dir!(staging_dir) do
    File.mkdir_p!(Path.dirname(staging_dir))
    File.mkdir!(staging_dir)

    File.write!(
      Path.join(staging_dir, @marker_filename),
      "Generated by mix llm_db.npm.export.\n"
    )
  end

  defp replace_output_dir!(staging_dir, output_dir) do
    validate_output_dir!(output_dir)

    case File.stat(output_dir) do
      {:error, :enoent} ->
        rename!(staging_dir, output_dir)

      {:ok, %File.Stat{type: :directory}} ->
        backup_dir = unique_sibling_path(output_dir, "backup")
        rename!(output_dir, backup_dir)

        case File.rename(staging_dir, output_dir) do
          :ok ->
            File.rm_rf(backup_dir)
            :ok

          {:error, replace_reason} ->
            case File.rename(backup_dir, output_dir) do
              :ok ->
                raise File.Error,
                  reason: replace_reason,
                  action: "replace NPM export directory",
                  path: output_dir

              {:error, rollback_reason} ->
                raise "could not replace NPM export directory " <>
                        "(#{inspect(replace_reason)}) or restore the prior export " <>
                        "(#{inspect(rollback_reason)}): #{output_dir}"
            end
        end
    end
  end

  defp rename!(source, destination) do
    case File.rename(source, destination) do
      :ok ->
        :ok

      {:error, reason} ->
        raise File.Error,
          reason: reason,
          action: "rename #{source} to",
          path: destination
    end
  end

  defp unique_sibling_path(path, kind) do
    suffix = System.unique_integer([:positive, :monotonic])
    Path.join(Path.dirname(path), ".#{Path.basename(path)}.#{kind}-#{suffix}")
  end
end
