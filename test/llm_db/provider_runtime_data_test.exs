defmodule LLMDB.ProviderRuntimeDataTest do
  use ExUnit.Case, async: true

  alias LLMDB.Provider
  alias LLMDB.Sources.Local

  @openai_compatible [
    :openai,
    :openrouter,
    :groq,
    :xai,
    :zenmux,
    :mistral,
    :togetherai,
    :github_models,
    :perplexity,
    :cloudflare_workers_ai,
    :fireworks_ai,
    :minimax,
    :friendli,
    :ollama_cloud,
    :deepseek,
    :alibaba,
    :venice,
    :cerebras,
    :zai
  ]

  test "provider TOML owns every executable provider runtime policy" do
    {:ok, providers} = Local.load(%{dir: "priv/llm_db/local"})

    Enum.each(@openai_compatible, fn id ->
      runtime = provider_runtime(providers, id)

      assert is_binary(runtime.base_url), "missing runtime base URL for #{id}"
      assert runtime.auth.type == "bearer"

      assert is_list(runtime.auth.env) and runtime.auth.env != [],
             "missing runtime auth env for #{id}"

      assert runtime.execution.text == "openai_chat_compatible"
      assert runtime.execution.object == "openai_chat_compatible"
    end)

    for {id, family} <- [
          anthropic: "anthropic_messages",
          google: "google_generate_content",
          cohere: "cohere_chat"
        ] do
      runtime = provider_runtime(providers, id)
      assert runtime.execution.text == family
      assert is_list(runtime.auth.env) and runtime.auth.env != []
    end

    elevenlabs = provider_runtime(providers, :elevenlabs)
    assert elevenlabs.auth.env == ["ELEVENLABS_API_KEY"]
    assert elevenlabs.execution.speech == "elevenlabs_speech"
    assert elevenlabs.execution.transcription == "elevenlabs_transcription"

    typesafe = provider_runtime(providers, :typesafe)
    assert typesafe.base_url == "https://api.typesafe.ai"
    assert typesafe.auth.type == "bearer"
    assert typesafe.auth.env == ["TYPESAFE_API_KEY"]
    assert typesafe.execution.evaluate == "typesafe_systemone"
    assert Map.get(typesafe.execution, :text) == nil
    assert Map.get(typesafe.execution, :object) == nil
  end

  defp provider_runtime(providers, id) do
    providers
    |> Map.fetch!(Atom.to_string(id))
    |> Map.delete(:models)
    |> Map.put(:id, id)
    |> Provider.new!()
    |> Map.fetch!(:runtime)
  end
end
