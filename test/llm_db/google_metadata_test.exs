defmodule LLMDB.GoogleMetadataTest do
  use ExUnit.Case, async: true

  alias LLMDB.{Model, Normalize, Provider}
  alias LLMDB.Sources.Local

  @local_dir "priv/llm_db/local"

  @retired_lifecycle %{
    "gemini-2.0-flash" => {"2026-06-01", "gemini-3.5-flash"},
    "gemini-2.0-flash-001" => {"2026-06-01", "gemini-3.5-flash"},
    "gemini-2.0-flash-lite" => {"2026-06-01", "gemini-3.1-flash-lite"},
    "gemini-2.0-flash-lite-001" => {"2026-06-01", "gemini-3.1-flash-lite"},
    "gemini-3-pro-preview" => {"2026-03-09", "gemini-3.1-pro-preview"},
    "gemini-3.1-flash-lite-preview" => {"2026-05-25", "gemini-3.1-flash-lite"},
    "gemini-robotics-er-1.5-preview" => {"2026-04-30", "gemini-robotics-er-1.6-preview"}
  }

  @deprecated_lifecycle %{
    "gemini-2.5-flash" => {"2026-10-16", "gemini-3.5-flash"},
    "gemini-2.5-flash-image" => {"2026-10-02", "gemini-3.1-flash-image"},
    "gemini-2.5-flash-lite" => {"2026-10-16", "gemini-3.1-flash-lite"},
    "gemini-2.5-pro" => {"2026-10-16", "gemini-3.1-pro-preview"},
    "gemini-3.1-flash-image-preview" => {"2026-06-25", "gemini-3.1-flash-image"},
    "gemini-3-pro-image-preview" => {"2026-06-25", "gemini-3-pro-image"},
    "gemini-3.1-flash-lite" => {"2027-05-07", nil},
    "gemini-embedding-001" => {"2026-07-14", "gemini-embedding-2"},
    "imagen-4.0-fast-generate-001" => {"2026-06-24", nil},
    "imagen-4.0-generate-001" => {"2026-06-24", nil},
    "imagen-4.0-ultra-generate-001" => {"2026-06-24", nil}
  }

  test "Google provider metadata points at Gemini API docs and accepted API key env vars" do
    {provider, _models} = google_provider_and_models()

    assert provider.doc == "https://ai.google.dev/gemini-api/docs"
    assert provider.env == ["GOOGLE_API_KEY", "GEMINI_API_KEY"]
  end

  test "local Google overrides codify official Gemini deprecation schedules" do
    {_provider, models} = google_provider_and_models()

    Enum.each(@retired_lifecycle, fn {model_id, {retires_at, replacement}} ->
      model = Map.fetch!(models, model_id)

      assert model.lifecycle.status == "retired"
      assert model.lifecycle.retires_at == retires_at
      assert model.lifecycle.replacement == replacement
      assert model.deprecated
      assert model.retired
      assert Model.effective_status(model, ~U[2026-06-08 00:00:00Z]) == "retired"
    end)

    Enum.each(@deprecated_lifecycle, fn {model_id, {retires_at, replacement}} ->
      model = Map.fetch!(models, model_id)

      assert model.lifecycle.status == "deprecated"
      assert model.lifecycle.retires_at == retires_at
      assert Map.get(model.lifecycle, :replacement) == replacement
      assert model.deprecated
      refute model.retired
    end)
  end

  test "local Google overrides capture docs-only image and embedding metadata" do
    {_provider, models} = google_provider_and_models()

    flash_image = Map.fetch!(models, "gemini-3.1-flash-image")
    assert flash_image.limits.context == 131_072
    assert flash_image.limits.output == 32_768
    assert flash_image.cost.input == 0.5
    assert flash_image.cost.output == 3.0
    assert flash_image.modalities.input == [:text, :image, :pdf]
    assert flash_image.modalities.output == [:text, :image]
    assert flash_image.capabilities.reasoning.enabled
    assert pricing_rate(flash_image, "image.output.4k") == 0.151

    pro_image = Map.fetch!(models, "gemini-3-pro-image")
    assert pro_image.limits.context == 65_536
    assert pro_image.limits.output == 32_768
    assert pro_image.cost.input == 2.0
    assert pro_image.cost.output == 12.0
    assert pro_image.capabilities.json.schema
    assert pricing_rate(pro_image, "image.output.4096x4096") == 0.24

    embedding = Map.fetch!(models, "gemini-embedding-2")
    assert embedding.limits.context == 8192
    assert embedding.cost.input == 0.20
    assert embedding.cost.image == 0.45
    assert embedding.cost.audio == 6.50
    assert embedding.cost.input_video == 12.00
    assert embedding.modalities.input == [:text, :image, :video, :audio, :pdf]
    assert embedding.modalities.output == [:embedding]
    assert embedding.capabilities.embeddings.min_dimensions == 128
    assert embedding.capabilities.embeddings.max_dimensions == 3072
  end

  test "local Google overrides capture Gemini 3.8 Flash metadata" do
    {_provider, models} = google_provider_and_models()
    model = Map.fetch!(models, "gemini-3.8-flash")

    assert model.name == "Gemini 3.8 Flash"
    assert model.doc_url == "https://ai.google.dev/gemini-api/docs/models/gemini-3.8-flash"
    assert model.release_date == "2026-09-02"
    assert model.knowledge == "2026-03"
    assert model.limits.context == 1_048_576
    assert model.limits.input == 1_048_576
    assert model.limits.output == 65_536
    assert model.cost.input == 0.75
    assert model.cost.output == 3.75
    assert model.cost.cache_read == 0.075
    assert pricing_rate(model, "token.input.batch") == 0.375
    assert pricing_rate(model, "token.output.batch") == 1.875
    assert pricing_rate(model, "token.cache_read.batch") == 0.0375
    assert model.modalities.input == [:text, :image, :video, :audio, :pdf]
    assert model.modalities.output == [:text]
    assert model.capabilities.reasoning.enabled
    assert model.capabilities.reasoning.effort.supported
    assert model.capabilities.reasoning.effort.values == ["low", "medium", "high"]
    assert model.capabilities.tools.enabled
    assert model.capabilities.json.schema
    assert model.capabilities.caching.type == "explicit"
    assert model.capabilities.batch.supported
    assert model.capabilities.code_execution.supported
    assert model.lifecycle.status == "active"
    assert model.extra.availability == "general"
  end

  defp google_provider_and_models do
    {:ok, data} = Local.load(%{dir: @local_dir})
    google = Map.fetch!(data, "google")
    provider = google |> Map.delete(:models) |> Map.put(:id, :google) |> Provider.new!()

    models =
      google.models
      |> Normalize.normalize_models()
      |> Enum.map(&Model.new!/1)
      |> Map.new(&{&1.id, &1})

    {provider, models}
  end

  defp pricing_rate(model, component_id) do
    model.pricing.components
    |> Enum.find(&(&1.id == component_id))
    |> Map.fetch!(:rate)
  end
end
