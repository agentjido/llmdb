defmodule LLMDB.MinimaxLifecycleMetadataTest do
  use ExUnit.Case, async: true

  alias LLMDB.{Model, Normalize}
  alias LLMDB.Sources.Local

  @local_dir "priv/llm_db/local"
  @providers ~w[minimax minimax_cn minimax_coding_plan minimax_cn_coding_plan]
  @retired_ids ~w[MiniMax-M2 MiniMax-M2.1]

  @deprecated_ids ~w[
    MiniMax-M2.5
    MiniMax-M2.5-highspeed
    MiniMax-M2.7
    MiniMax-M2.7-highspeed
  ]

  @deprecated_at "2026-10-19"
  @retires_at "2026-11-18"
  @replacement "MiniMax-M3.1-Flash"

  setup_all do
    {:ok, local} = Local.load(%{dir: @local_dir})
    snapshot = "priv/llm_db/snapshot.json" |> File.read!() |> Jason.decode!()
    %{local: local, packaged: snapshot["providers"]}
  end

  test "retired MiniMax M2 family is marked across every MiniMax provider", %{local: local} do
    for provider <- @providers, id <- @retired_ids do
      model = local_model(local, provider, id)

      assert model.lifecycle == %{status: "retired"}
      assert model.retired
      assert model.deprecated
      assert Model.lifecycle_status(model) == "retired"
    end
  end

  test "M2.5 and M2.7 families carry the retirement schedule", %{local: local} do
    for provider <- @providers, id <- @deprecated_ids do
      model = local_model(local, provider, id)

      assert model.lifecycle == %{
               status: "deprecated",
               deprecated_at: @deprecated_at,
               retires_at: @retires_at,
               replacement: @replacement
             }

      assert model.deprecated
      refute model.retired
    end
  end

  test "packaged snapshot publishes the MiniMax lifecycle metadata", %{packaged: packaged} do
    for provider <- @providers do
      for id <- @retired_ids do
        model = packaged_model(packaged, provider, id)

        assert model["lifecycle"] == %{"status" => "retired"}
        assert model["retired"]
        assert model["deprecated"]
      end

      for id <- @deprecated_ids do
        model = packaged_model(packaged, provider, id)

        assert model["lifecycle"] == %{
                 "status" => "deprecated",
                 "deprecated_at" => @deprecated_at,
                 "retires_at" => @retires_at,
                 "replacement" => @replacement
               }

        assert model["deprecated"]
        refute model["retired"]
      end
    end
  end

  test "scheduled retirement advances at the documented date", %{local: local} do
    model = local_model(local, "minimax", "MiniMax-M2.7")

    before_retirement = ~U[2026-11-17 23:59:59Z]
    retirement = ~U[2026-11-18 00:00:00Z]

    assert Model.effective_status(model, before_retirement) == "deprecated"
    assert Model.effective_status(model, retirement) == "retired"
    refute Model.retired?(model, before_retirement)
    assert Model.retired?(model, retirement)
  end

  defp local_model(local, provider, id) do
    local
    |> Map.fetch!(provider)
    |> Map.fetch!(:models)
    |> Normalize.normalize_models()
    |> Enum.find(&(&1.id == id))
    |> Model.new!()
  end

  defp packaged_model(packaged, provider, id) do
    packaged
    |> Map.fetch!(provider)
    |> Map.fetch!("models")
    |> Map.fetch!(id)
  end
end
