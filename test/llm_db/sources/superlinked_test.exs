defmodule LLMDB.Sources.SuperlinkedTest do
  use ExUnit.Case, async: false

  alias LLMDB.{Engine, Model, Source}
  alias LLMDB.Sources.{Remote, Superlinked}

  @url "https://api.superlinked.com/v1/models"

  setup do
    cache_dir =
      Path.join(System.tmp_dir!(), "llmdb-superlinked-#{System.unique_integer([:positive])}")

    original_superlinked_key = System.get_env("SUPERLINKED_API_KEY")
    original_sie_key = System.get_env("SIE_API_KEY")
    System.delete_env("SUPERLINKED_API_KEY")
    System.delete_env("SIE_API_KEY")

    on_exit(fn ->
      File.rm_rf!(cache_dir)
      restore_env("SUPERLINKED_API_KEY", original_superlinked_key)
      restore_env("SIE_API_KEY", original_sie_key)
    end)

    %{
      opts: %{cache_dir: cache_dir},
      remote_opts: [cache_dir: cache_dir, cache_key: "superlinked"]
    }
  end

  describe "transform/1" do
    test "maps chat, dense embedding, and rerank contracts without claiming native operations" do
      chat =
        model("Qwen/Qwen3.5-4B", ["tokens"])
        |> Map.merge(%{
          "inputs" => ["text", "image"],
          "max_sequence_length" => 8192,
          "aliases" => ["qwen-chat"],
          "capabilities" => %{
            "grammar" => ["json_schema", "regex"],
            "streaming" => true,
            "tools" => true
          }
        })

      dense =
        model("Qwen/Qwen3-Embedding-4B", ["dense"])
        |> Map.merge(%{
          "dims" => %{"dense" => 2560},
          "max_sequence_length" => 32_768,
          "profiles" => ["default", "flash"]
        })

      rerank = model("Qwen/Qwen3-Reranker-0.6B", ["score"])
      native = model("BAAI/bge-m3", ["sparse", "multivector", "json"])

      data = Superlinked.transform(%{"models" => [native, rerank, dense, chat]})

      assert :ok = Source.assert_canonical!(data)
      assert provider = data["superlinked"]
      assert provider.id == :superlinked
      assert provider.name == "Superlinked SIE"
      assert provider.base_url == "https://api.superlinked.com/v1"
      assert provider.doc == "https://superlinked.com/docs/integrations"
      assert provider.env == ["SIE_API_KEY", "SUPERLINKED_API_KEY"]
      assert provider.runtime.auth == %{type: "bearer", env: provider.env}
      assert provider.runtime.execution.embed == "openai_embeddings"
      refute Map.has_key?(provider.runtime.execution, :object)

      models = Map.new(provider.models, &{&1.id, &1})

      assert chat_model = models["Qwen/Qwen3.5-4B"]
      refute chat_model.catalog_only
      assert chat_model.modalities == %{input: [:text, :image], output: [:text]}
      assert chat_model.limits == %{context: 8192}
      assert chat_model.aliases == ["qwen-chat"]
      assert chat_model.capabilities.chat
      assert chat_model.capabilities.tools.enabled
      assert chat_model.capabilities.tools.streaming
      assert chat_model.capabilities.json.schema
      assert chat_model.capabilities.json.strict
      assert chat_model.capabilities.streaming.text
      assert chat_model.execution.text.path == "/chat/completions"
      assert chat_model.execution.object.path == "/chat/completions"

      assert dense_model = models["Qwen/Qwen3-Embedding-4B"]
      refute dense_model.catalog_only
      refute dense_model.capabilities.chat

      assert dense_model.capabilities.embeddings == %{
               min_dimensions: 2560,
               max_dimensions: 2560,
               default_dimensions: 2560
             }

      assert dense_model.modalities == %{input: [:text], output: [:embedding]}
      assert dense_model.execution.embed.path == "/embeddings"
      refute Map.has_key?(dense_model.execution, :text)

      assert rerank_model = models["Qwen/Qwen3-Reranker-0.6B"]
      assert rerank_model.catalog_only
      assert rerank_model.capabilities.rerank
      refute rerank_model.capabilities.embeddings
      refute Map.has_key?(rerank_model, :execution)

      assert native_model = models["BAAI/bge-m3"]
      assert native_model.catalog_only
      refute native_model.capabilities.embeddings
      refute native_model.capabilities.rerank
      refute native_model.capabilities.chat
      refute Map.has_key?(native_model, :execution)

      for model <- provider.models do
        assert {:ok, %Model{}} = Model.new(model)
      end
    end

    test "drops malformed models and unsafe numeric metadata" do
      malformed =
        model("malformed", ["tokens"])
        |> Map.merge(%{
          "max_sequence_length" => 0,
          "dims" => %{"dense" => "many"},
          "inputs" => ["text", "unknown", 42]
        })

      data = Superlinked.transform(%{"models" => [nil, %{}, malformed]})
      assert data["superlinked"].models == []
      assert Superlinked.transform(nil)["superlinked"].models == []
    end
  end

  describe "authenticated pull and offline load" do
    test "missing credentials make no request", ctx do
      request = fn _url, _opts -> flunk("unexpected request") end

      assert {:error, :no_api_key} =
               Superlinked.pull(%{cache_dir: ctx.opts.cache_dir, req_opts: [request: request]})
    end

    test "uses bearer authentication and preserves safe request options", ctx do
      request = fn url, opts ->
        assert url == @url
        assert opts[:headers] == [{"authorization", "Bearer test-key"}, {"x-test", "present"}]
        assert opts[:retry] == false
        assert opts[:decode_body] == false
        response([model("cached", ["tokens"])])
      end

      opts =
        Map.merge(ctx.opts, %{
          api_key: "test-key",
          req_opts: [request: request, retry: false, headers: [{"x-test", "present"}]]
        })

      assert {:ok, path} = Superlinked.pull(opts)
      assert File.exists?(path)
      refute File.read!(path) =~ "test-key"
      manifest = path |> String.replace_suffix(".json", ".manifest.json") |> File.read!()
      refute manifest =~ "test-key"
      assert Jason.decode!(manifest)["source_url"] == @url
    end

    test "accepts both environment variable names and gives an explicit key precedence", ctx do
      for {superlinked_key, sie_key, explicit_key, expected} <- [
            {"superlinked-key", "sie-key", nil, "sie-key"},
            {nil, "sie-key", nil, "sie-key"},
            {"superlinked-key", "sie-key", "explicit-key", "explicit-key"}
          ] do
        restore_env("SUPERLINKED_API_KEY", superlinked_key)
        restore_env("SIE_API_KEY", sie_key)

        request = fn _url, opts ->
          assert {"authorization", "Bearer " <> expected} in opts[:headers]
          response([])
        end

        assert {:ok, _path} =
                 Superlinked.pull(
                   ctx.opts
                   |> Map.put(:api_key, explicit_key)
                   |> Map.put(:req_opts, request: request)
                 )
      end
    end

    test "load reads only the cache and validates its shape", ctx do
      request = fn _url, _opts -> flunk("load must not make a network request") end

      assert {:error, :no_cache} =
               Superlinked.load(Map.put(ctx.opts, :req_opts, request: request))

      assert {:ok, _path} = Remote.store(@url, %{"unexpected" => []}, ctx.remote_opts)
      assert {:error, :invalid_response} = Superlinked.load(ctx.opts)
    end

    test "account-specific and empty replies preserve earlier models", ctx do
      seed_cache(ctx.remote_opts, [
        model("Qwen/Qwen3.5-4B", ["tokens"]),
        model("Qwen/Qwen3-Embedding-4B", ["dense"])
      ])

      latest =
        model("Qwen/Qwen3-Embedding-4B", ["dense"])
        |> Map.put("revision", "new-revision")

      for models <- [[latest], []] do
        request = fn _url, _opts -> response(models) end

        assert {:ok, _path} =
                 Superlinked.pull(
                   Map.merge(ctx.opts, %{api_key: "test-key", req_opts: [request: request]})
                 )

        assert {:ok, data} = Superlinked.load(ctx.opts)

        assert Enum.map(data["superlinked"].models, & &1.id) == [
                 "Qwen/Qwen3-Embedding-4B",
                 "Qwen/Qwen3.5-4B"
               ]

        assert hd(data["superlinked"].models).extra.revision == "new-revision"
      end
    end

    test "the cached source builds executable provider and model data", ctx do
      seed_cache(ctx.remote_opts, [
        model("Qwen/Qwen3.5-4B", ["tokens"]),
        model("Qwen/Qwen3-Embedding-4B", ["dense"])
        |> Map.put("dims", %{"dense" => 2560}),
        model("Qwen/Qwen3-Reranker-0.6B", ["score"])
      ])

      assert {:ok, snapshot} = Engine.run(sources: [{Superlinked, ctx.opts}])
      provider = snapshot.providers.superlinked
      assert provider.name == "Superlinked SIE"
      assert provider.runtime.base_url == "https://api.superlinked.com/v1"
      assert provider.runtime.auth.type == "bearer"
      assert provider.runtime.auth.env == ["SIE_API_KEY", "SUPERLINKED_API_KEY"]

      assert provider.models["Qwen/Qwen3.5-4B"].execution.text.path == "/chat/completions"
      assert provider.models["Qwen/Qwen3-Embedding-4B"].execution.embed.path == "/embeddings"
      assert provider.models["Qwen/Qwen3-Reranker-0.6B"].capabilities.rerank
      assert provider.models["Qwen/Qwen3-Reranker-0.6B"].catalog_only
    end

    test "HTTP, transport, and invalid response failures preserve the cache and hide credentials",
         ctx do
      path = seed_cache(ctx.remote_opts, [model("cached", ["tokens"])])
      original = File.read!(path)

      for {result, expected} <- [
            {{:ok, %Req.Response{status: 401, body: "test-key"}}, {:http_status, 401}},
            {{:error, %{authorization: "test-key"}}, :request_failed},
            {{:ok, %Req.Response{status: 200, body: "not-json test-key"}}, :invalid_response},
            {{:ok, %Req.Response{status: 200, body: %{"models" => "invalid"}}}, :invalid_response}
          ] do
        request = fn _url, _opts -> result end

        assert {:error, ^expected} =
                 Superlinked.pull(
                   Map.merge(ctx.opts, %{api_key: "test-key", req_opts: [request: request]})
                 )

        assert File.read!(path) == original
      end
    end
  end

  defp model(name, outputs) do
    %{
      "name" => name,
      "inputs" => ["text"],
      "outputs" => outputs,
      "dims" => %{},
      "capabilities" => %{},
      "aliases" => [],
      "loaded" => true,
      "last_error" => "must not be cached"
    }
  end

  defp response(models) do
    {:ok,
     %Req.Response{
       status: 200,
       body: %{"object" => "list", "data" => [], "models" => models},
       headers: %{}
     }}
  end

  defp seed_cache(opts, models) do
    {:ok, path} =
      Remote.store(@url, %{"object" => "list", "data" => [], "models" => models}, opts)

    path
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
