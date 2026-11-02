defmodule LLMDB.AlbertDataTest do
  use ExUnit.Case, async: true

  alias LLMDB.Engine
  alias LLMDB.Sources.Local

  @model_ids ~w(
    bge-m3
    bge-reranker-v2-m3
    deepseek-v4-flash
    gemma-4-31b-it
    gpt-oss-120b
    lightonocr-2-1b
    ministral-3-8b-instruct-2512
    mistral-medium-3-5
    mistral-ocr-2512
    mistral-small-3-2-24b-instruct-2506
    qwen3-coder-30b-a3b-instruct
    qwen3-vl-embedding-8b
    whisper-large-v3
  )

  setup_all do
    dir = Path.expand("../../priv/llm_db/local", __DIR__)

    dir_reader = fn
      ^dir -> ["albert"]
      path -> File.ls!(path)
    end

    assert {:ok, snapshot} =
             Engine.run(sources: [{Local, %{dir: dir, dir_reader: dir_reader}}])

    %{provider: snapshot.providers.albert, models: snapshot.providers.albert.models}
  end

  test "all thirteen documented models survive the source pipeline", %{models: models} do
    assert Enum.sort(Map.keys(models)) == @model_ids
    assert Enum.all?(models, fn {id, model} -> model.id == id and model.provider == :albert end)
  end

  test "provider identifies its private government audience and authorized runtime", %{
    provider: provider
  } do
    assert provider.name == "Albert API"

    assert provider.extra.description ==
             "Private provider for French government bodies, operated by DINUM; access requires authorization."

    assert provider.runtime.base_url == "https://albert.api.etalab.gouv.fr/v1"
    assert provider.runtime.auth.type == "bearer"
    assert provider.runtime.auth.env == ["ALBERT_API_KEY"]
    assert provider.catalog_only
  end

  test "documented aliases stay on their concrete models", %{models: models} do
    aliases = %{
      "openweight-small" => "ministral-3-8b-instruct-2512",
      "openweight-medium" => "mistral-small-3-2-24b-instruct-2506",
      "openweight-large" => "gpt-oss-120b",
      "openweight-code" => "qwen3-coder-30b-a3b-instruct",
      "openweight-ocr" => "lightonocr-2-1b",
      "openweight-embeddings" => "bge-m3",
      "openweight-rerank" => "bge-reranker-v2-m3",
      "openweight-audio" => "whisper-large-v3",
      "mistral-medium-2508" => "mistral-medium-3-5",
      "mistral-medium-latest" => "mistral-medium-3-5",
      "deepseek-ai/DeepSeek-V4-Flash-0731" => "deepseek-v4-flash",
      "google/gemma-4-31B-it" => "gemma-4-31b-it"
    }

    for {alias_id, model_id} <- aliases do
      assert alias_id in models[model_id].aliases
      refute Map.has_key?(models, alias_id)
    end

    all_aliases = Enum.flat_map(models, fn {_id, model} -> model.aliases end)
    assert length(all_aliases) == length(Enum.uniq(all_aliases))
  end

  test "all models inherit catalog-only status without executable contracts", %{models: models} do
    for {_id, model} <- models do
      assert model.catalog_only
      assert model.execution == nil
    end
  end

  test "chat models retain documented capabilities", %{models: models} do
    chat_models = Enum.filter(models, fn {_id, model} -> model.capabilities.chat end)
    assert length(chat_models) == 8

    for {_id, model} <- chat_models do
      assert Map.get(model.limits, :output) == nil
    end

    assert models["ministral-3-8b-instruct-2512"].limits.context == 262_144
    assert :image in models["ministral-3-8b-instruct-2512"].modalities.input
    assert models["ministral-3-8b-instruct-2512"].capabilities.tools.enabled
    assert models["gpt-oss-120b"].capabilities.reasoning.enabled
    assert models["gemma-4-31b-it"].capabilities.reasoning.enabled
    assert models["mistral-medium-3-5"].capabilities.reasoning.enabled
  end

  test "embeddings and transcription retain descriptive metadata", %{models: models} do
    for id <- ["bge-m3", "qwen3-vl-embedding-8b", "whisper-large-v3"] do
      model = models[id]
      assert model.catalog_only
      refute model.capabilities.chat
      assert model.execution == nil
    end

    assert models["bge-m3"].capabilities.embeddings.max_dimensions == 1024

    qwen = models["qwen3-vl-embedding-8b"]
    assert qwen.capabilities.embeddings.min_dimensions == 4096
    assert qwen.capabilities.embeddings.max_dimensions == 4096
    assert qwen.capabilities.embeddings.default_dimensions == 4096
    assert :image in qwen.modalities.input

    whisper = models["whisper-large-v3"]
    assert whisper.extra.diarization
    assert whisper.extra.max_audio_file_size_mb == 20
    assert whisper.limits == nil
  end

  test "reranking and document OCR remain descriptive rather than chat models", %{models: models} do
    for id <- ["bge-reranker-v2-m3", "mistral-ocr-2512"] do
      assert models[id].catalog_only
      refute models[id].capabilities.chat
      assert models[id].execution == nil
    end

    assert models["bge-reranker-v2-m3"].capabilities.rerank
    assert models["bge-reranker-v2-m3"].limits.context == 8192
    assert models["bge-reranker-v2-m3"].extra.recommended_max_input_tokens == 1024
    assert models["bge-reranker-v2-m3"].extra.endpoint == "/v1/rerank"
    assert models["mistral-ocr-2512"].extra.endpoint == "/v1/ocr"
    assert :pdf in models["mistral-ocr-2512"].modalities.input
  end

  test "free prices are explicit only for models listed on the pricing page", %{models: models} do
    unpriced = ~w(gemma-4-31b-it mistral-medium-3-5 mistral-ocr-2512)

    for {id, model} <- models do
      if id in unpriced do
        assert model.cost == nil
      else
        assert model.cost.input == 0.0
        assert model.cost.output == 0.0
      end
    end
  end

  test "experimental dates do not imply retirement and partner access is retained", %{
    models: models
  } do
    for id <- ~w(deepseek-v4-flash gemma-4-31b-it qwen3-vl-embedding-8b) do
      assert "experimental" in models[id].tags
      assert models[id].extra.experimental
      refute models[id].retired
      refute models[id].deprecated
    end

    assert models["qwen3-vl-embedding-8b"].extra.experiment_end == "2026-10-01"

    for id <- ~w(mistral-medium-3-5 mistral-ocr-2512) do
      assert "partner" in models[id].tags
      assert models[id].extra.partner
    end
  end

  test "packaged snapshot includes the provider, audience description and complete inventory" do
    snapshot = "priv/llm_db/snapshot.json" |> File.read!() |> Jason.decode!()
    provider = snapshot["providers"]["albert"]

    assert provider["extra"]["description"] =~ "Private provider for French government bodies"
    assert Enum.sort(Map.keys(provider["models"])) == @model_ids
    assert provider["catalog_only"] == true
    assert provider["runtime"]["base_url"] == "https://albert.api.etalab.gouv.fr/v1"
    assert provider["runtime"]["auth"]["env"] == ["ALBERT_API_KEY"]

    for {_id, model} <- provider["models"] do
      assert model["catalog_only"] == true
      assert model["execution"] == nil
    end
  end
end
