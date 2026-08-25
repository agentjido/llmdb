defmodule LLMDB.MiniMaxMetadataTest do
  use ExUnit.Case, async: true

  alias LLMDB.{ExecutionContract, Model, Normalize, Provider}
  alias LLMDB.Sources.Local

  @local_dir "priv/llm_db/local"
  @providers ~w(minimax minimax_cn minimax_coding_plan minimax_cn_coding_plan)

  test "image-01 metadata covers reference-image input and provider-specific billing" do
    {:ok, data} = Local.load(%{dir: @local_dir})

    Enum.each(@providers, fn provider_id ->
      model = image_model(data, provider_id)

      assert model.release_date == "2025-02-15"
      assert model.modalities.input == [:text, :image]
      assert model.modalities.output == [:image]

      expected_rate = if String.ends_with?(provider_id, "coding_plan"), do: 0.0, else: 0.0035
      assert pricing_rate(model, "image.generated") == expected_rate
    end)
  end

  test "MiniMax image execution uses the native image generation endpoint" do
    {:ok, data} = Local.load(%{dir: @local_dir})
    minimax = Map.fetch!(data, "minimax")

    provider =
      minimax
      |> Map.delete(:models)
      |> Map.put(:id, :minimax)
      |> Provider.new!()
      |> ExecutionContract.enrich_provider()

    model =
      data
      |> image_model("minimax")
      |> ExecutionContract.enrich_model(provider)

    assert model.execution.image.family == "minimax_images"
    assert model.execution.image.wire_protocol == "minimax_images"
    assert model.execution.image.path == "/image_generation"
  end

  defp image_model(data, provider_id) do
    data
    |> Map.fetch!(provider_id)
    |> Map.fetch!(:models)
    |> Normalize.normalize_models()
    |> Enum.map(&Model.new!/1)
    |> Enum.find(&(&1.id == "image-01"))
  end

  defp pricing_rate(model, component_id) do
    model.pricing.components
    |> Enum.find(&(&1.id == component_id))
    |> Map.fetch!(:rate)
  end
end
