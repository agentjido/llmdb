defmodule LLMDB.PackagedTest do
  use ExUnit.Case, async: true

  alias LLMDB.Packaged

  @local_cohere_dir Path.expand("../../priv/llm_db/local/cohere", __DIR__)
  @local_cohere_rerank_model_ids "rerank-*.toml"
                                 |> then(&Path.join(@local_cohere_dir, &1))
                                 |> Path.wildcard()
                                 |> Enum.map(fn path ->
                                   path
                                   |> File.read!()
                                   |> Toml.decode!()
                                   |> Map.fetch!("id")
                                 end)
                                 |> Enum.sort()
  @local_nearai_dir Path.expand("../../priv/llm_db/local/nearai", __DIR__)
  @local_nearai_chat_model_ids "*.toml"
                               |> then(&Path.join(@local_nearai_dir, &1))
                               |> Path.wildcard()
                               |> Enum.reject(&String.ends_with?(&1, "/provider.toml"))
                               |> Enum.map(fn path ->
                                 path
                                 |> File.read!()
                                 |> Toml.decode!()
                                 |> Map.fetch!("id")
                               end)
                               |> Enum.sort()
  @local_opencode_dir Path.expand("../../priv/llm_db/local/opencode", __DIR__)
  @local_opencode_execution_model_ids "*.toml"
                                      |> then(&Path.join(@local_opencode_dir, &1))
                                      |> Path.wildcard()
                                      |> Enum.reject(&String.ends_with?(&1, "/provider.toml"))
                                      |> Enum.map(fn path ->
                                        path
                                        |> File.read!()
                                        |> Toml.decode!()
                                        |> Map.fetch!("id")
                                      end)
                                      |> Enum.sort()

  describe "snapshot_path/0" do
    test "returns correct snapshot path" do
      path = Packaged.snapshot_path()
      assert String.ends_with?(path, "priv/llm_db/snapshot.json")
      assert is_binary(path)
    end
  end

  describe "snapshot/0" do
    test "loads snapshot from priv directory" do
      snapshot = Packaged.snapshot()

      if snapshot do
        assert is_map(snapshot)
        assert snapshot["version"] == 2
        assert is_binary(snapshot["snapshot_id"])
        assert is_binary(snapshot["generated_at"])
        assert is_map(snapshot["providers"])
      else
        assert snapshot == nil
      end
    end

    test "snapshot providers have expected structure" do
      snapshot = Packaged.snapshot()

      if snapshot && map_size(snapshot["providers"]) > 0 do
        {provider_id, provider} = Enum.at(snapshot["providers"], 0)
        assert is_atom(provider_id) or is_binary(provider_id)
        assert Map.has_key?(provider, "id")
        assert Map.has_key?(provider, "models")
        assert is_map(provider["models"])
      end
    end

    test "snapshot models have expected structure" do
      snapshot = Packaged.snapshot()

      if snapshot && map_size(snapshot["providers"]) > 0 do
        {_provider_id, provider} = Enum.at(snapshot["providers"], 0)

        if map_size(provider["models"]) > 0 do
          {model_id, model} = Enum.at(provider["models"], 0)
          assert is_binary(model_id) or is_atom(model_id)
          assert Map.has_key?(model, "id")
          assert Map.has_key?(model, "provider")
        end
      end
    end

    test "snapshot carries representative provider runtime metadata" do
      snapshot = Packaged.snapshot()

      if snapshot do
        openai = snapshot["providers"]["openai"]
        anthropic = snapshot["providers"]["anthropic"]
        fireworks = snapshot["providers"]["fireworks_ai"]
        minimax = snapshot["providers"]["minimax"]
        nearai = snapshot["providers"]["nearai"]
        moonshot = snapshot["providers"]["moonshotai"]
        moonshot_cn = snapshot["providers"]["moonshotai_cn"]
        opencode = snapshot["providers"]["opencode"]

        assert openai["runtime"]["auth"]["type"] == "bearer"
        assert openai["runtime"]["base_url"] == "https://api.openai.com/v1"
        assert anthropic["runtime"]["auth"]["type"] == "x_api_key"
        assert anthropic["runtime"]["auth"]["header_name"] == "x-api-key"
        assert fireworks["base_url"] == "https://api.fireworks.ai/inference/v1"
        assert fireworks["runtime"]["base_url"] == "https://api.fireworks.ai/inference/v1"
        assert minimax["base_url"] == "https://api.minimax.io/v1"
        assert minimax["runtime"]["base_url"] == "https://api.minimax.io/v1"
        assert nearai["runtime"]["base_url"] == "https://cloud-api.near.ai/v1"
        assert nearai["runtime"]["auth"]["type"] == "bearer"
        assert nearai["runtime"]["auth"]["env"] == ["NEARAI_API_KEY"]
        refute Map.get(nearai, "catalog_only", false)
        assert moonshot["runtime"]["auth"]["type"] == "bearer"
        assert moonshot["runtime"]["base_url"] == "https://api.moonshot.ai/v1"
        assert moonshot["runtime"]["doc_url"] == "https://platform.kimi.ai/docs/api/chat"
        assert moonshot_cn["runtime"]["auth"]["type"] == "bearer"
        assert moonshot_cn["runtime"]["base_url"] == "https://api.moonshot.cn/v1"
        assert opencode["runtime"]["auth"]["type"] == "bearer"
        assert opencode["runtime"]["auth"]["env"] == ["OPENCODE_API_KEY"]
        assert opencode["runtime"]["base_url"] == "https://opencode.ai/zen/v1"
        refute Map.get(opencode, "catalog_only", false)
      end
    end

    test "snapshot carries representative model execution metadata" do
      snapshot = Packaged.snapshot()

      if snapshot do
        responses_model = snapshot["providers"]["openai"]["models"]["gpt-4.1"]
        speech_model = snapshot["providers"]["openai"]["models"]["gpt-4o-mini-tts"]
        google_model = snapshot["providers"]["google"]["models"]["gemini-2.5-pro"]
        elevenlabs_model = snapshot["providers"]["elevenlabs"]["models"]["eleven_flash_v2_5"]
        claude_opus_4 = snapshot["providers"]["anthropic"]["models"]["claude-opus-4-20250514"]

        claude_opus_4_1 =
          snapshot["providers"]["anthropic"]["models"]["claude-opus-4-1-20250805"]

        assert responses_model["execution"]["text"]["family"] == "openai_responses_compatible"
        assert speech_model["execution"]["speech"]["family"] == "openai_speech"
        assert google_model["execution"]["text"]["family"] == "google_generate_content"
        assert elevenlabs_model["execution"]["speech"]["family"] == "elevenlabs_speech"
        assert claude_opus_4["execution"]["text"]["family"] == "anthropic_messages"
        refute Map.has_key?(claude_opus_4["execution"], "object")
        assert claude_opus_4_1["execution"]["object"]["family"] == "anthropic_messages"
      end
    end

    test "snapshot includes GLM-5.3 for the Z.AI Coding Plan" do
      snapshot = Packaged.snapshot()

      if snapshot do
        model = snapshot["providers"]["zai_coding_plan"]["models"]["glm-5.3"]

        assert model["provider_model_id"] == "glm-5.3"
        assert model["limits"] == %{"context" => 1_000_000, "output" => 131_072}
        assert model["modalities"] == %{"input" => ["text"], "output" => ["text"]}
        assert model["capabilities"]["reasoning"]["enabled"]

        assert model["capabilities"]["reasoning"]["effort"] == %{
                 "default" => "max",
                 "supported" => true,
                 "values" => ["low", "high", "max"]
               }

        assert model["capabilities"]["reasoning"]["thinking"] == %{
                 "default_type" => "enabled",
                 "disable_supported" => false,
                 "supported" => true,
                 "types" => ["enabled"]
               }
      end
    end

    test "snapshot maps recent OpenAI GPT-5 text and tool models to Responses API" do
      snapshot = Packaged.snapshot()

      if snapshot do
        openai_models = snapshot["providers"]["openai"]["models"]

        for model_id <- [
              "gpt-5.3-chat-latest",
              "gpt-5.3-codex",
              "gpt-5.3-codex-spark",
              "gpt-5.4",
              "gpt-5.4-2026-03-05",
              "gpt-5.4-mini",
              "gpt-5.4-mini-2026-03-17",
              "gpt-5.4-nano",
              "gpt-5.4-nano-2026-03-17",
              "gpt-5.4-pro",
              "gpt-5.4-pro-2026-03-05",
              "gpt-5.5",
              "gpt-5.5-2026-04-23",
              "gpt-5.5-pro",
              "gpt-5.5-pro-2026-04-23"
            ] do
          model = openai_models[model_id]

          assert is_map(model), "expected #{model_id} in packaged OpenAI snapshot"
          assert model["execution"]["text"]["family"] == "openai_responses_compatible"
          assert model["execution"]["text"]["wire_protocol"] == "openai_responses"
          assert model["execution"]["text"]["path"] == "/responses"
          assert model["execution"]["object"]["family"] == "openai_responses_compatible"
          assert model["execution"]["object"]["wire_protocol"] == "openai_responses"
          assert model["execution"]["object"]["path"] == "/responses"
        end
      end
    end

    test "snapshot carries NEAR AI chat execution metadata for local runtime overrides" do
      snapshot = Packaged.snapshot()

      if snapshot do
        assert Enum.any?(@local_nearai_chat_model_ids)

        nearai_models = snapshot["providers"]["nearai"]["models"]

        for model_id <- @local_nearai_chat_model_ids do
          model = nearai_models[model_id]

          assert is_map(model),
                 "expected local NEAR AI chat model #{inspect(model_id)} in packaged snapshot"

          assert model["id"] == model_id
          refute Map.get(model, "catalog_only", false)
          assert model["execution"]["text"]["family"] == "openai_chat_compatible"
          assert model["execution"]["text"]["wire_protocol"] == "openai_chat"
          assert model["execution"]["text"]["path"] == "/chat/completions"
          assert model["execution"]["object"]["family"] == "openai_chat_compatible"
          assert model["execution"]["object"]["wire_protocol"] == "openai_chat"
          assert model["execution"]["object"]["path"] == "/chat/completions"
        end
      end
    end

    test "snapshot carries Moonshot OpenAI-chat execution metadata for current models" do
      snapshot = Packaged.snapshot()

      if snapshot do
        for provider_id <- ["moonshotai", "moonshotai_cn"],
            model_id <- [
              "kimi-k2.5",
              "kimi-k2.6",
              "kimi-k2.7-code",
              "kimi-k2.7-code-highspeed"
            ] do
          model = snapshot["providers"][provider_id]["models"][model_id]

          refute model["catalog_only"] == true
          assert model["execution"]["text"]["family"] == "openai_chat_compatible"
          assert model["execution"]["text"]["wire_protocol"] == "openai_chat"
          assert model["execution"]["text"]["path"] == "/chat/completions"
          assert model["execution"]["object"]["family"] == "openai_chat_compatible"
          assert model["execution"]["object"]["wire_protocol"] == "openai_chat"
          assert model["execution"]["object"]["path"] == "/chat/completions"
        end
      end
    end

    test "snapshot carries verified Moonshot Kimi K3 metadata" do
      snapshot = Packaged.snapshot()

      if snapshot do
        model = snapshot["providers"]["moonshotai"]["models"]["kimi-k3"]

        refute model["catalog_only"] == true
        assert model["limits"]["context"] == 1_048_576
        assert model["limits"]["output"] == 1_048_576
        assert model["cost"] == %{"cache_read" => 0.3, "input" => 3, "output" => 15}

        assert model["modalities"] == %{
                 "input" => ["text", "image", "video"],
                 "output" => ["text"]
               }

        assert model["capabilities"]["reasoning"]["enabled"] == true

        assert model["capabilities"]["json"] == %{
                 "native" => true,
                 "schema" => true,
                 "strict" => true
               }

        assert model["extra"]["reasoning_options"] == [
                 %{"type" => "effort", "values" => ["max"]}
               ]

        assert model["extra"]["temperature"] == false

        assert model["extra"]["constraints"] == %{
                 "reasoning_effort" => "required",
                 "temperature" => "fixed_1",
                 "token_limit_key" => "max_completion_tokens"
               }

        assert model["execution"]["text"]["family"] == "openai_chat_compatible"
        assert model["execution"]["text"]["wire_protocol"] == "openai_chat"
        assert model["execution"]["text"]["path"] == "/chat/completions"
        assert model["execution"]["object"]["family"] == "openai_chat_compatible"
        assert model["execution"]["object"]["wire_protocol"] == "openai_chat"
        assert model["execution"]["object"]["path"] == "/chat/completions"
      end
    end

    test "snapshot carries Moonshot Kimi K2.5 retirement metadata" do
      snapshot = Packaged.snapshot()

      if snapshot do
        model = snapshot["providers"]["moonshotai"]["models"]["kimi-k2.5"]

        assert model["deprecated"] == true
        assert model["retired"] == false
        assert model["lifecycle"]["status"] == "deprecated"
        assert model["lifecycle"]["deprecated_at"] == "2026-07-17"
        assert model["lifecycle"]["retires_at"] == "2026-08-31"
        assert model["lifecycle"]["replacement"] == "kimi-k3"
      end
    end

    test "snapshot keeps discontinued Moonshot K2 models catalog-only" do
      snapshot = Packaged.snapshot()

      if snapshot do
        for provider_id <- ["moonshotai", "moonshotai_cn"],
            model_id <- [
              "kimi-k2-0711-preview",
              "kimi-k2-0905-preview",
              "kimi-k2-thinking",
              "kimi-k2-thinking-turbo",
              "kimi-k2-turbo-preview"
            ] do
          model = snapshot["providers"][provider_id]["models"][model_id]

          assert model["catalog_only"] == true
          assert model["execution"] == nil
          assert model["retired"] == true
          assert model["lifecycle"]["status"] == "retired"
          assert model["lifecycle"]["retires_at"] == "2026-05-25"
          assert model["lifecycle"]["replacement"] == "kimi-k2.6"
        end
      end
    end

    test "snapshot carries OpenCode Zen execution metadata for documented live models" do
      snapshot = Packaged.snapshot()

      if snapshot do
        assert length(@local_opencode_execution_model_ids) == 48

        opencode_models = snapshot["providers"]["opencode"]["models"]

        samples = [
          {"gpt-5.5", "openai_responses_compatible", "openai_responses", "/responses"},
          {"claude-fable-5", "anthropic_messages", "anthropic_messages", "/messages"},
          {"gemini-3.5-flash", "google_generate_content", "google_generate_content",
           "/models/gemini-3.5-flash"},
          {"deepseek-v4-pro", "openai_chat_compatible", "openai_chat", "/chat/completions"}
        ]

        for {model_id, family, wire_protocol, path} <- samples do
          model = opencode_models[model_id]

          assert is_map(model), "expected OpenCode model #{inspect(model_id)} in snapshot"
          refute Map.get(model, "catalog_only", false)
          assert model["execution"]["text"]["family"] == family
          assert model["execution"]["text"]["wire_protocol"] == wire_protocol
          assert model["execution"]["text"]["path"] == path
        end
      end
    end

    test "snapshot leaves unverified OpenCode Zen models catalog-only" do
      snapshot = Packaged.snapshot()

      if snapshot do
        opencode_models = snapshot["providers"]["opencode"]["models"]

        for model_id <- ["claude-3-5-haiku", "qwen3-coder"] do
          model = opencode_models[model_id]

          assert is_map(model), "expected OpenCode model #{inspect(model_id)} in snapshot"
          assert model["catalog_only"] == true
          assert model["execution"] == nil
        end
      end
    end

    test "snapshot carries rerank capability metadata for packaged local rerank models" do
      snapshot = Packaged.snapshot()

      if snapshot do
        assert Enum.any?(@local_cohere_rerank_model_ids)

        cohere_models = snapshot["providers"]["cohere"]["models"]

        for model_id <- @local_cohere_rerank_model_ids do
          model = cohere_models[model_id]

          assert is_map(model),
                 "expected local Cohere rerank model #{inspect(model_id)} in packaged snapshot"

          assert model["capabilities"]["rerank"] == true
          assert model["capabilities"]["chat"] == false
          assert model["capabilities"]["embeddings"] == false
          assert model["capabilities"]["streaming"]["text"] == false
          assert model["execution"] == nil
        end
      end
    end
  end
end
