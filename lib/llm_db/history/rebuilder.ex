defmodule LLMDB.History.Rebuilder do
  @moduledoc """
  Rebuilds snapshot-based history artifacts from an ordered snapshot observation chain.

  The observation chain is typically sourced from `snapshot-index.json` and contains
  entries keyed by immutable `snapshot_id`, with optional provenance such as
  `captured_at`, `source_commit`, and `parent_snapshot_id`.

  Direct use is documentation-deprecated in favor of
  `mix llm_db.history.rebuild`.
  """

  alias LLMDB.{History.Diff, History.Lineage, Snapshot}

  @lineage_overrides_file "lineage_overrides.json"
  @transaction_dir ".incremental-transaction"
  @transaction_manifest "manifest.json"
  @checkpoint_schema_version 1
  @type observation :: map()

  @type summary :: %{
          mode: :full | :incremental,
          snapshots_written: non_neg_integer(),
          unique_snapshots_written: non_neg_integer(),
          snapshots_processed: non_neg_integer(),
          events_written: non_neg_integer(),
          events_added: non_neg_integer(),
          output_dir: String.t(),
          snapshot_index_path: String.t(),
          latest_path: String.t(),
          from_snapshot_id: String.t() | nil,
          to_snapshot_id: String.t() | nil
        }

  @spec rebuild(keyword()) :: {:ok, summary()} | {:error, term()}
  def rebuild(opts) when is_list(opts) do
    observations =
      opts
      |> Keyword.get(:observations, [])
      |> Enum.map(&stringify_observation/1)

    snapshot_loader = Keyword.fetch!(opts, :snapshot_loader)
    output_dir = output_dir(opts)
    snapshot_index_path = snapshot_index_path(opts, output_dir)
    latest_path = latest_path(opts, output_dir)
    source = Keyword.get(opts, :source)
    mode = Keyword.get(opts, :mode, :auto)
    incremental_commit_hook = Keyword.get(opts, :incremental_commit_hook, fn -> :ok end)

    with :ok <- recover_interrupted_update(output_dir),
         :ok <- validate_observations(observations),
         {:ok, lineage_overrides} <- load_lineage_overrides(output_dir),
         {:ok, checkpoint} <-
           load_checkpoint(
             mode,
             output_dir,
             snapshot_index_path,
             latest_path,
             observations,
             lineage_overrides
           ) do
      case checkpoint do
        :full ->
          rebuild_full(
            observations,
            snapshot_loader,
            lineage_overrides,
            output_dir,
            snapshot_index_path,
            latest_path,
            source
          )

        checkpoint ->
          rebuild_incremental(
            observations,
            snapshot_loader,
            lineage_overrides,
            output_dir,
            snapshot_index_path,
            latest_path,
            source,
            checkpoint,
            incremental_commit_hook
          )
      end
    end
  end

  defp rebuild_full(
         observations,
         snapshot_loader,
         lineage_overrides,
         output_dir,
         snapshot_index_path,
         latest_path,
         source
       ) do
    with :ok <- prepare_output_dir(output_dir),
         {:ok, result} <-
           rebuild_records(
             observations,
             snapshot_loader,
             lineage_overrides,
             initial_state(),
             0
           ),
         :ok <-
           write_full_outputs(
             output_dir,
             snapshot_index_path,
             latest_path,
             observations,
             result,
             source,
             lineage_overrides
           ) do
      {:ok,
       summary(
         :full,
         observations,
         length(observations),
         result.events_written,
         result.events_written,
         output_dir,
         snapshot_index_path,
         latest_path
       )}
    end
  end

  defp rebuild_incremental(
         observations,
         snapshot_loader,
         lineage_overrides,
         output_dir,
         snapshot_index_path,
         latest_path,
         source,
         checkpoint,
         incremental_commit_hook
       ) do
    pending_observations = Enum.drop(observations, checkpoint.observation_count)

    if pending_observations == [] do
      {:ok,
       summary(
         :incremental,
         observations,
         0,
         checkpoint.events_written,
         0,
         output_dir,
         snapshot_index_path,
         latest_path
       )}
    else
      initial = %{
        previous_models: checkpoint.previous_models,
        previous_lineage_by_key: checkpoint.previous_lineage_by_key,
        snapshot_records: [],
        events_by_year: %{},
        events_written: 0,
        has_previous: true
      }

      with {:ok, result} <-
             rebuild_records(
               pending_observations,
               snapshot_loader,
               lineage_overrides,
               initial,
               checkpoint.observation_count
             ),
           :ok <-
             append_outputs(
               output_dir,
               snapshot_index_path,
               latest_path,
               observations,
               result,
               source,
               lineage_overrides,
               checkpoint.events_written,
               incremental_commit_hook
             ) do
        total_events = checkpoint.events_written + result.events_written

        {:ok,
         summary(
           :incremental,
           observations,
           length(pending_observations),
           total_events,
           result.events_written,
           output_dir,
           snapshot_index_path,
           latest_path
         )}
      end
    end
  end

  defp initial_state do
    %{
      previous_models: %{},
      previous_lineage_by_key: %{},
      snapshot_records: [],
      events_by_year: %{},
      events_written: 0,
      has_previous: false
    }
  end

  defp rebuild_records(
         observations,
         snapshot_loader,
         lineage_overrides,
         initial,
         observation_offset
       ) do
    result =
      observations
      |> Enum.with_index(observation_offset + 1)
      |> Enum.reduce_while(initial, fn {observation, observation_idx}, acc ->
        case snapshot_loader.(observation["snapshot_id"]) do
          {:ok, snapshot} ->
            current_models = flatten_snapshot_models(snapshot)

            {events, current_lineage_by_key} =
              case acc.has_previous do
                false ->
                  current_lineage_by_key = Lineage.initialize(current_models, lineage_overrides)

                  events =
                    Diff.models(%{}, current_models)
                    |> Lineage.attach(%{}, current_lineage_by_key)

                  {events, current_lineage_by_key}

                true ->
                  current_lineage_by_key =
                    Lineage.resolve(
                      acc.previous_models,
                      current_models,
                      acc.previous_lineage_by_key,
                      lineage_overrides
                    )

                  events =
                    Diff.models(acc.previous_models, current_models)
                    |> Lineage.attach(acc.previous_lineage_by_key, current_lineage_by_key)

                  {events, current_lineage_by_key}
              end

            counts = Snapshot.counts(snapshot)
            captured_at = observation["captured_at"] || snapshot["generated_at"]

            snapshot_record =
              %{
                "schema_version" => Snapshot.schema_version(),
                "snapshot_id" => observation["snapshot_id"],
                "source_commit" => observation["source_commit"],
                "captured_at" => captured_at,
                "manifest_generated_at" => observation["manifest_generated_at"],
                "parent_snapshot_id" => observation["parent_snapshot_id"],
                "provider_count" => observation["provider_count"] || counts.provider_count,
                "model_count" => observation["model_count"] || map_size(current_models),
                "digest" => Diff.snapshot_digest(current_models),
                "event_count" => length(events)
              }
              |> compact_nils()

            events_by_year =
              Enum.with_index(events, 1)
              |> Enum.reduce(acc.events_by_year, fn {event, event_idx}, inner_acc ->
                year = captured_at |> to_string() |> String.slice(0, 4)

                record =
                  %{
                    "schema_version" => Snapshot.schema_version(),
                    "event_id" => event_id(observation, observation_idx, event_idx),
                    "snapshot_id" => observation["snapshot_id"],
                    "source_commit" => observation["source_commit"],
                    "captured_at" => captured_at,
                    "type" => event.type,
                    "model_key" => event.model_key,
                    "lineage_key" => Map.get(event, :lineage_key, event.model_key),
                    "provider" => provider_from_model_key(event.model_key),
                    "model_id" => model_id_from_model_key(event.model_key),
                    "changes" => event.changes
                  }
                  |> compact_nils()

                Map.update(inner_acc, year, [record], &[record | &1])
              end)

            {:cont,
             %{
               previous_models: current_models,
               previous_lineage_by_key: current_lineage_by_key,
               snapshot_records: [snapshot_record | acc.snapshot_records],
               events_by_year: events_by_year,
               events_written: acc.events_written + length(events),
               has_previous: true
             }}

          {:error, reason} ->
            {:halt, {:error, {observation["snapshot_id"], reason}}}
        end
      end)

    case result do
      {:error, _reason} = error ->
        error

      state ->
        {:ok,
         %{
           snapshot_records: Enum.reverse(state.snapshot_records),
           events_by_year:
             Map.new(state.events_by_year, fn {year, records} ->
               {year, Enum.reverse(records)}
             end),
           events_written: state.events_written,
           previous_models: state.previous_models,
           previous_lineage_by_key: state.previous_lineage_by_key
         }}
    end
  end

  defp write_full_outputs(
         output_dir,
         snapshot_index_path,
         latest_path,
         observations,
         result,
         source,
         lineage_overrides
       ) do
    write_ndjson(Path.join(output_dir, "snapshots.ndjson"), result.snapshot_records)

    Enum.each(result.events_by_year, fn {year, records} ->
      write_ndjson(Path.join([output_dir, "events", "#{year}.ndjson"]), records)
    end)

    write_index_and_latest(snapshot_index_path, latest_path, observations)

    write_meta(output_dir, snapshot_index_path, observations, result.events_written, source)
    write_checkpoint(output_dir, observations, result, lineage_overrides)
  end

  defp append_outputs(
         output_dir,
         snapshot_index_path,
         latest_path,
         observations,
         result,
         source,
         lineage_overrides,
         previous_event_count,
         incremental_commit_hook
       ) do
    transaction =
      begin_incremental_transaction(
        output_dir,
        snapshot_index_path,
        latest_path,
        observations,
        result
      )

    append_ndjson(Path.join(output_dir, "snapshots.ndjson"), result.snapshot_records)

    Enum.each(result.events_by_year, fn {year, records} ->
      append_ndjson(Path.join([output_dir, "events", "#{year}.ndjson"]), records)
    end)

    write_index_and_latest(snapshot_index_path, latest_path, observations)

    write_meta(
      output_dir,
      snapshot_index_path,
      observations,
      previous_event_count + result.events_written,
      source
    )

    incremental_commit_hook.()
    write_checkpoint(output_dir, observations, result, lineage_overrides)
    finish_incremental_transaction(transaction)
  end

  defp write_index_and_latest(snapshot_index_path, latest_path, observations) do
    Snapshot.write!(snapshot_index_path, %{
      "schema_version" => Snapshot.schema_version(),
      "snapshots" => observations
    })

    case List.last(observations) do
      nil -> :ok
      latest -> Snapshot.write!(latest_path, latest)
    end

    :ok
  end

  defp write_meta(output_dir, snapshot_index_path, observations, event_count, source) do
    Snapshot.write!(Path.join(output_dir, "meta.json"), %{
      "schema_version" => Snapshot.schema_version(),
      "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => source,
      "snapshots_written" => length(observations),
      "unique_snapshots_written" =>
        observations |> Enum.map(& &1["snapshot_id"]) |> MapSet.new() |> MapSet.size(),
      "events_written" => event_count,
      "event_count" => event_count,
      "from_snapshot_id" => observations |> List.first() |> snapshot_id_from_observation(),
      "to_snapshot_id" => observations |> List.last() |> snapshot_id_from_observation(),
      "snapshot_index_path" => snapshot_index_path
    })
  end

  defp write_checkpoint(output_dir, observations, result, lineage_overrides) do
    Snapshot.write!(Path.join(output_dir, Snapshot.history_state_filename()), %{
      "checkpoint_schema_version" => @checkpoint_schema_version,
      "observation_count" => length(observations),
      "to_snapshot_id" => observations |> List.last() |> snapshot_id_from_observation(),
      "previous_models" => result.previous_models,
      "previous_lineage_by_key" => result.previous_lineage_by_key,
      "lineage_overrides_digest" => term_digest(lineage_overrides)
    })
  end

  defp flatten_snapshot_models(%{"providers" => providers}) when is_map(providers) do
    providers
    |> Enum.sort_by(fn {provider_id, _provider} -> to_string(provider_id) end)
    |> Enum.reduce(%{}, fn {provider_id, provider}, acc ->
      provider_id = provider["id"] || provider[:id] || to_string(provider_id)

      provider
      |> Map.get("models", provider[:models] || %{})
      |> Enum.sort_by(fn {model_id, _model} -> to_string(model_id) end)
      |> Enum.reduce(acc, fn {model_id, model}, inner_acc ->
        model_id = to_string(model_id)

        normalized =
          model
          |> stringify_map()
          |> Map.put_new("id", model_id)
          |> Map.put_new("provider", provider_id)
          |> Diff.normalize()

        Map.put(inner_acc, "#{provider_id}:#{model_id}", normalized)
      end)
    end)
  end

  defp flatten_snapshot_models(_), do: %{}

  defp load_lineage_overrides(output_dir) do
    path = Path.join(output_dir, @lineage_overrides_file)

    if not File.exists?(path) do
      {:ok, %{}}
    else
      with {:ok, content} <- File.read(path),
           {:ok, decoded} <- Jason.decode(content),
           {:ok, overrides} <- parse_lineage_overrides(decoded) do
        {:ok, overrides}
      else
        {:error, reason} ->
          {:error, "invalid lineage overrides at #{path}: #{inspect(reason)}"}
      end
    end
  end

  defp parse_lineage_overrides(%{"lineage" => lineage}) when is_map(lineage),
    do: validate_lineage_overrides(lineage)

  defp parse_lineage_overrides(map) when is_map(map), do: validate_lineage_overrides(map)
  defp parse_lineage_overrides(_), do: {:error, :invalid_format}

  defp validate_lineage_overrides(lineage_overrides) do
    Enum.reduce_while(lineage_overrides, {:ok, %{}}, fn {from, to}, {:ok, acc} ->
      if is_binary(from) and is_binary(to) do
        {:cont, {:ok, Map.put(acc, from, to)}}
      else
        {:halt, {:error, :non_string_keys_or_values}}
      end
    end)
  end

  defp load_checkpoint(
         :full,
         _output_dir,
         _index_path,
         _latest_path,
         _observations,
         _lineage_overrides
       ),
       do: {:ok, :full}

  defp load_checkpoint(
         :auto,
         output_dir,
         index_path,
         latest_path,
         observations,
         lineage_overrides
       ) do
    state_path = Path.join(output_dir, Snapshot.history_state_filename())
    meta_path = Path.join(output_dir, "meta.json")
    snapshots_path = Path.join(output_dir, "snapshots.ndjson")

    checkpoint =
      with {:ok, state} <- read_json(state_path),
           @checkpoint_schema_version <- state["checkpoint_schema_version"],
           observation_count when is_integer(observation_count) and observation_count > 0 <-
             state["observation_count"],
           true <- observation_count <= length(observations),
           previous_models when is_map(previous_models) <- state["previous_models"],
           previous_lineage_by_key when is_map(previous_lineage_by_key) <-
             state["previous_lineage_by_key"],
           true <- state["lineage_overrides_digest"] == term_digest(lineage_overrides),
           true <- managed_path?(index_path, output_dir),
           true <- managed_path?(latest_path, output_dir),
           {:ok, %{"snapshots" => existing_observations}} when is_list(existing_observations) <-
             read_json(index_path),
           existing_observations <- Enum.map(existing_observations, &stringify_observation/1),
           true <- length(existing_observations) == observation_count,
           true <- Enum.take(observations, observation_count) == existing_observations,
           to_snapshot_id <-
             existing_observations |> List.last() |> snapshot_id_from_observation(),
           true <- state["to_snapshot_id"] == to_snapshot_id,
           {:ok, meta} <- read_json(meta_path),
           true <- meta["to_snapshot_id"] == to_snapshot_id,
           events_written when is_integer(events_written) and events_written >= 0 <-
             meta["event_count"] || meta["events_written"],
           true <- File.exists?(snapshots_path),
           true <- File.dir?(Path.join(output_dir, "events")) do
        %{
          observation_count: observation_count,
          events_written: events_written,
          previous_models: previous_models,
          previous_lineage_by_key: previous_lineage_by_key
        }
      else
        _reason -> :full
      end

    {:ok, checkpoint}
  end

  defp load_checkpoint(
         mode,
         _output_dir,
         _index_path,
         _latest_path,
         _observations,
         _lineage_overrides
       ),
       do: {:error, {:invalid_rebuild_mode, mode}}

  defp begin_incremental_transaction(
         output_dir,
         snapshot_index_path,
         latest_path,
         observations,
         result
       ) do
    transaction_dir = Path.join(output_dir, @transaction_dir)
    backup_dir = Path.join(transaction_dir, "control")

    data_paths =
      [Path.join(output_dir, "snapshots.ndjson")] ++
        Enum.map(Map.keys(result.events_by_year), fn year ->
          Path.join([output_dir, "events", "#{year}.ndjson"])
        end)

    control_paths = [
      snapshot_index_path,
      latest_path,
      Path.join(output_dir, "meta.json"),
      Path.join(output_dir, Snapshot.history_state_filename())
    ]

    File.rm_rf!(transaction_dir)
    File.mkdir_p!(backup_dir)

    Enum.each(control_paths, fn path ->
      if File.exists?(path) do
        backup_path = transaction_backup_path(backup_dir, output_dir, path)
        File.mkdir_p!(Path.dirname(backup_path))
        File.cp!(path, backup_path)
      end
    end)

    manifest = %{
      "target_observation_count" => length(observations),
      "target_snapshot_id" => observations |> List.last() |> snapshot_id_from_observation(),
      "data_files" =>
        Map.new(data_paths, fn path ->
          {Path.relative_to(path, output_dir), file_size(path)}
        end),
      "control_files" => Enum.map(control_paths, &Path.relative_to(&1, output_dir))
    }

    Snapshot.write!(Path.join(transaction_dir, @transaction_manifest), manifest)
    %{dir: transaction_dir}
  end

  defp finish_incremental_transaction(%{dir: transaction_dir}) do
    File.rm_rf!(transaction_dir)
    :ok
  end

  defp recover_interrupted_update(output_dir) do
    transaction_dir = Path.join(output_dir, @transaction_dir)
    manifest_path = Path.join(transaction_dir, @transaction_manifest)

    cond do
      not File.dir?(transaction_dir) ->
        :ok

      not File.exists?(manifest_path) ->
        File.rm_rf!(transaction_dir)
        :ok

      true ->
        with {:ok, manifest} <- read_json(manifest_path) do
          if transaction_committed?(output_dir, manifest) do
            File.rm_rf!(transaction_dir)
          else
            rollback_transaction(output_dir, transaction_dir, manifest)
          end

          :ok
        else
          _error ->
            File.rm_rf!(transaction_dir)
            :ok
        end
    end
  end

  defp transaction_committed?(output_dir, manifest) do
    state_path = Path.join(output_dir, Snapshot.history_state_filename())

    case read_json(state_path) do
      {:ok, state} ->
        state["observation_count"] == manifest["target_observation_count"] and
          state["to_snapshot_id"] == manifest["target_snapshot_id"]

      _error ->
        false
    end
  end

  defp rollback_transaction(output_dir, transaction_dir, manifest) do
    Enum.each(manifest["data_files"] || %{}, fn {relative_path, original_size} ->
      path = managed_transaction_path!(output_dir, relative_path)
      restore_file_size(path, original_size)
    end)

    backup_dir = Path.join(transaction_dir, "control")

    Enum.each(manifest["control_files"] || [], fn relative_path ->
      path = managed_transaction_path!(output_dir, relative_path)
      backup_path = managed_transaction_path!(backup_dir, relative_path)

      if File.exists?(backup_path) do
        File.mkdir_p!(Path.dirname(path))
        File.cp!(backup_path, path)
      else
        File.rm_rf!(path)
      end
    end)

    File.rm_rf!(transaction_dir)
  end

  defp restore_file_size(path, nil), do: File.rm_rf!(path)

  defp restore_file_size(path, size) when is_integer(size) and size >= 0 do
    File.open!(path, [:read, :write], fn file ->
      {:ok, ^size} = :file.position(file, size)
      :ok = :file.truncate(file)
    end)
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, stat} -> stat.size
      {:error, :enoent} -> nil
    end
  end

  defp transaction_backup_path(backup_dir, output_dir, path) do
    relative_path = Path.relative_to(path, output_dir)
    managed_transaction_path!(backup_dir, relative_path)
  end

  defp managed_transaction_path!(root, relative_path) do
    path = Path.expand(relative_path, root)

    if managed_path?(path, root) do
      path
    else
      raise "invalid history transaction path: #{relative_path}"
    end
  end

  defp managed_path?(path, root) do
    expanded_path = Path.expand(path)
    expanded_root = Path.expand(root)
    expanded_path == expanded_root or String.starts_with?(expanded_path, expanded_root <> "/")
  end

  defp read_json(path) do
    with {:ok, content} <- File.read(path),
         {:ok, decoded} <- Jason.decode(content) do
      {:ok, decoded}
    end
  end

  defp term_digest(term) do
    term
    |> Snapshot.encode()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp summary(
         mode,
         observations,
         snapshots_processed,
         events_written,
         events_added,
         output_dir,
         snapshot_index_path,
         latest_path
       ) do
    %{
      mode: mode,
      snapshots_written: length(observations),
      unique_snapshots_written:
        observations |> Enum.map(& &1["snapshot_id"]) |> MapSet.new() |> MapSet.size(),
      snapshots_processed: snapshots_processed,
      events_written: events_written,
      events_added: events_added,
      output_dir: output_dir,
      snapshot_index_path: snapshot_index_path,
      latest_path: latest_path,
      from_snapshot_id: observations |> List.first() |> snapshot_id_from_observation(),
      to_snapshot_id: observations |> List.last() |> snapshot_id_from_observation()
    }
  end

  defp provider_from_model_key(model_key) do
    model_key
    |> String.split(":", parts: 2)
    |> List.first()
  end

  defp model_id_from_model_key(model_key) do
    case String.split(model_key, ":", parts: 2) do
      [_provider, model_id] -> model_id
      _ -> model_key
    end
  end

  defp event_id(observation, observation_idx, event_idx) do
    observation_key =
      observation["source_commit"] ||
        observation["captured_at"] ||
        Integer.to_string(observation_idx)

    "#{observation["snapshot_id"]}:#{observation_key}:#{event_idx}"
  end

  defp stringify_observation(observation) when is_map(observation), do: stringify_map(observation)

  defp stringify_map(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} ->
      {
        to_string(key),
        cond do
          is_map(value) -> stringify_map(value)
          is_list(value) -> Enum.map(value, &stringify_nested/1)
          true -> value
        end
      }
    end)
    |> Map.new()
  end

  defp stringify_nested(value) when is_map(value), do: stringify_map(value)
  defp stringify_nested(value), do: value

  defp validate_observations([]), do: {:error, :no_snapshots}

  defp validate_observations(observations) do
    case Enum.find(observations, &(not is_binary(&1["snapshot_id"]))) do
      nil -> :ok
      invalid -> {:error, {:invalid_observation, invalid}}
    end
  end

  defp prepare_output_dir(output_dir) do
    File.rm_rf!(Path.join(output_dir, "events"))
    File.rm_rf!(Path.join(output_dir, "snapshots.ndjson"))
    File.rm_rf!(Path.join(output_dir, "meta.json"))
    File.rm_rf!(Path.join(output_dir, Snapshot.snapshot_index_filename()))
    File.rm_rf!(Path.join(output_dir, Snapshot.latest_filename()))
    File.rm_rf!(Path.join(output_dir, Snapshot.history_state_filename()))
    File.rm_rf!(Path.join(output_dir, @transaction_dir))
    File.mkdir_p!(Path.join(output_dir, "events"))
    :ok
  end

  defp write_ndjson(path, records) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()

    lines =
      records
      |> Enum.map(&Jason.encode!/1)
      |> Enum.join("\n")

    File.write!(path, lines <> if(lines == "", do: "", else: "\n"))
  end

  defp append_ndjson(_path, []), do: :ok

  defp append_ndjson(path, records) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()

    lines = records |> Enum.map(&Jason.encode!/1) |> Enum.join("\n")
    File.write!(path, lines <> "\n", [:append])
  end

  defp compact_nils(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp output_dir(opts) do
    opts
    |> Keyword.get(:output_dir, "priv/llm_db/history")
    |> expand_path()
  end

  defp snapshot_index_path(opts, output_dir) do
    opts
    |> Keyword.get(
      :snapshot_index_path,
      Path.join(output_dir, Snapshot.snapshot_index_filename())
    )
    |> expand_path()
  end

  defp latest_path(opts, output_dir) do
    opts
    |> Keyword.get(:latest_path, Path.join(output_dir, Snapshot.latest_filename()))
    |> expand_path()
  end

  defp snapshot_id_from_observation(nil), do: nil
  defp snapshot_id_from_observation(observation), do: observation["snapshot_id"]

  defp expand_path(path) when is_binary(path) do
    if Path.type(path) == :absolute do
      path
    else
      Path.expand(path)
    end
  end
end
