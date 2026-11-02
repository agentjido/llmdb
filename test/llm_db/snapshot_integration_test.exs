defmodule LLMDB.SnapshotIntegrationTest do
  use ExUnit.Case, async: false

  alias LLMDB.Snapshot
  alias LLMDB.Snapshot.Builder

  test "independent provider inputs integrate through one generated snapshot" do
    output_dir =
      Path.join(
        System.tmp_dir!(),
        "llmdb-snapshot-integration-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(output_dir) end)

    alpha = source(:integration_alpha, "alpha-model")
    beta = source(:integration_beta, "beta-model")

    assert {:ok, artifact} =
             Builder.build(sources: [alpha, beta], output_dir: output_dir)

    assert get_in(artifact.snapshot, ["providers", "integration_alpha", "models", "alpha-model"])
    assert get_in(artifact.snapshot, ["providers", "integration_beta", "models", "beta-model"])

    Builder.write!(artifact)
    assert {:ok, written} = Snapshot.read(artifact.snapshot_path, integrity_policy: :strict)
    assert written["snapshot_id"] == artifact.snapshot_id

    assert {:ok, reversed} =
             Builder.build(sources: [beta, alpha], output_dir: output_dir)

    assert reversed.snapshot_id == artifact.snapshot_id

    retimed = Map.put(reversed.snapshot, "generated_at", "2050-01-01T00:00:00Z")
    assert Snapshot.snapshot_id(retimed) == artifact.snapshot_id
  end

  defp source(provider, model_id) do
    {LLMDB.Sources.Config,
     %{
       overrides: %{
         providers: [%{id: provider, name: "Integration #{provider}"}],
         models: [
           %{
             id: model_id,
             provider: provider,
             capabilities: %{chat: true}
           }
         ]
       }
     }}
  end
end
