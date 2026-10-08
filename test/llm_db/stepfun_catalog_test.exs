defmodule LLMDB.StepFunCatalogTest do
  use ExUnit.Case, async: true

  alias LLMDB.Packaged

  test "packages separate China and Global runtime contracts" do
    for {id, host} <- [{"stepfun", "stepfun.com"}, {"stepfun_ai", "stepfun.ai"}] do
      provider = provider(id)

      refute provider["catalog_only"]
      assert provider["runtime"]["base_url"] == "https://api.#{host}/v1"
      assert provider["runtime"]["auth"]["type"] == "bearer"
      assert provider["runtime"]["auth"]["env"] == ["STEPFUN_API_KEY"]
    end
  end

  test "separates chat, speech, and SSE transcription operations" do
    for id <- ["stepfun", "stepfun_ai"] do
      models = provider(id)["models"]
      chat = models["stepaudio-3-chat-preview"]
      speech = models["stepaudio-3-tts"]
      asr = models["stepaudio-3-asr-max"]

      assert chat["modalities"]["input"] == ["text", "audio"]
      assert chat["execution"]["text"]["path"] == "/chat/completions"
      assert chat["capabilities"]["streaming"]["text"]
      assert chat["capabilities"]["reasoning"]["enabled"]
      refute Map.has_key?(chat["execution"], "transcription")
      assert speech["execution"]["speech"]["family"] == "openai_speech"
      assert speech["execution"]["speech"]["path"] == "/audio/speech"
      refute Map.has_key?(speech["execution"], "text")
      refute speech["capabilities"]["streaming"]["text"]
      assert asr["execution"]["transcription"]["family"] == "stepfun_transcription"
      assert asr["execution"]["transcription"]["wire_protocol"] == "stepfun_asr_sse"
      assert asr["execution"]["transcription"]["path"] == "/audio/asr/sse"
      refute Map.has_key?(asr["execution"], "text")
      refute asr["capabilities"]["streaming"]["text"]

      for model <- [chat, speech, asr] do
        refute model["catalog_only"]
      end
    end
  end

  test "keeps other audio transports outside the executable catalog" do
    for provider_id <- ["stepfun", "stepfun_ai"],
        model_id <- [
          "stepaudio-3-realtime-preview",
          "stepaudio-2.5-realtime",
          "stepaudio-2.5-asr-stream",
          "stepaudio-3-gen-preview",
          "stepaudio-3-music-preview"
        ] do
      model = provider(provider_id)["models"][model_id]

      assert model["catalog_only"], model_id
      refute model["capabilities"]["chat"]

      for {_operation, contract} <- model["execution"] || %{} do
        refute contract["supported"], model_id
      end
    end
  end

  test "records Global character and duration rates without token prices" do
    models = provider("stepfun_ai")["models"]
    tts = models["stepaudio-3-tts"]
    asr = models["stepaudio-3-asr-max"]

    assert tts["cost"] == nil
    assert asr["cost"] == nil
    assert tts["pricing"]["currency"] == "USD"
    assert [speech] = tts["pricing"]["components"]
    assert speech["meter"] == "input.billable_characters"
    assert speech["per"] == 10_000
    assert speech["rate"] == 0.36
    assert [recognition] = asr["pricing"]["components"]
    assert recognition["meter"] == "input.audio_seconds"
    assert recognition["per"] == 3600
    assert recognition["rate"] == 0.40
    assert provider("stepfun")["models"]["stepaudio-3-tts"]["pricing"] == nil
  end

  defp provider(id), do: Packaged.snapshot()["providers"][id]
end
