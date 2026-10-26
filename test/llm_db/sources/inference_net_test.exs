defmodule LLMDB.Sources.InferenceNetTest do
  use ExUnit.Case, async: true

  alias LLMDB.{Model, Source}
  alias LLMDB.Sources.{InferenceNet, Remote}

  @url "https://api.inference.net/v1/models"

  describe "transform/1" do
    test "maps public catalog fields to an executable provider and model" do
      source = model("deepseek-v4.1-flash-1017")
      result = InferenceNet.transform(%{"object" => "list", "data" => [source]})

      assert :ok = Source.assert_canonical!(result)
      assert provider = result["inference"]
      assert provider.id == :inference
      assert provider.name == "Inference.net"
      assert provider.base_url == "https://api.inference.net/v1"
      assert provider.env == ["INFERENCE_API_KEY"]
      assert "google/gemma-3" in provider.exclude_models
      refute provider.catalog_only
      assert provider.runtime.auth == %{type: "bearer", env: ["INFERENCE_API_KEY"]}

      assert [model] = provider.models
      assert model.id == source["id"]
      assert model.provider == :inference
      assert model.limits == %{context: 1_040_000, output: 393_216}
      assert model.cost == %{input: 0.3, output: 1.0, cache_read: 0.007}
      assert model.modalities == %{input: [:text, :image], output: [:text]}
      assert model.capabilities.reasoning.effort.values == ~w(none low high max)
      assert model.capabilities.tools.enabled
      assert model.capabilities.tools.streaming
      assert model.capabilities.tools.strict
      assert model.capabilities.json.schema
      assert model.capabilities.json.strict
      assert model.capabilities.streaming.text
      assert model.capabilities.streaming.tool_calls
      assert model.execution.text.path == "/chat/completions"
      assert model.execution.object.path == "/chat/completions"
      refute model.catalog_only
      assert {:ok, %Model{}} = Model.new(model)
    end

    test "marks published privileged models without retaining team access status" do
      source =
        model("deepseek-v4.1-flash-1017-cyber")
        |> Map.merge(%{"requires_approved_access" => true, "access_status" => "none"})

      [model] = InferenceNet.transform(%{"data" => [source]})["inference"].models

      assert model.tags == ["privileged"]
      assert model.extra.requires_approved_access
      refute Map.has_key?(model.extra, :access_status)
    end

    test "does not claim tool support for documented exceptions" do
      ids = [
        "llama-3.2-1b-instruct",
        "llama-3.2-3b-instruct",
        "inference-net/schematron-v2-small",
        "inference-net/schematron-v2-turbo"
      ]

      models =
        InferenceNet.transform(%{"data" => Enum.map(ids, &model/1)})["inference"].models

      assert Enum.map(models, & &1.id) == ids

      for model <- models do
        refute model.capabilities.tools.enabled
        refute model.capabilities.tools.streaming
        refute model.capabilities.streaming.tool_calls
        assert model.capabilities.json.schema
        assert model.execution.object.supported
      end
    end

    test "keeps non-chat entries as catalog-only records" do
      source = model("future-embedding") |> Map.put("supported_endpoints", ["embeddings"])
      [model] = InferenceNet.transform(%{"data" => [source]})["inference"].models

      assert model.catalog_only
      refute model.capabilities.chat
      refute model.capabilities.streaming.text
      refute Map.has_key?(model, :execution)
      assert {:ok, %Model{}} = Model.new(model)
    end

    test "drops malformed records and unsafe numeric metadata" do
      malformed =
        model("malformed")
        |> Map.merge(%{
          "context_length" => 0,
          "max_completion_tokens" => "large",
          "pricing" => %{
            "prompt" => "not-a-number",
            "completion" => "-0.1",
            "input_cache_read" => nil
          },
          "input_modalities" => ["text", "unknown", 42]
        })

      data = InferenceNet.transform(%{"data" => [nil, %{}, %{"id" => ""}, malformed]})
      assert [model] = data["inference"].models
      assert model.id == "malformed"
      refute Map.has_key?(model, :limits)
      refute Map.has_key?(model, :cost)
      assert model.modalities == %{input: [:text], output: [:text]}

      for content <- [nil, [], %{}, %{"data" => %{}}] do
        assert InferenceNet.transform(content)["inference"].models == []
      end
    end
  end

  describe "explicit pull and offline load" do
    setup do
      directory =
        Path.join(System.tmp_dir!(), "inference-net-source-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(directory) end)
      %{directory: directory}
    end

    test "load reads only the cache and validates its shape", %{directory: directory} do
      request = fn _url, _opts -> flunk("load/1 must not perform a network request") end
      opts = %{cache_dir: directory, request: request}
      assert {:error, :no_cache} = InferenceNet.load(opts)

      assert {:ok, _path} =
               Remote.store(@url, %{"unexpected" => []},
                 cache_dir: directory,
                 cache_key: "inference-net"
               )

      assert {:error, :invalid_catalog} = InferenceNet.load(opts)
    end

    test "pull needs no key and creates a reusable cache", %{directory: directory} do
      request = fn url, opts ->
        assert url == @url

        refute Enum.any?(opts[:headers], fn {name, _value} ->
                 String.downcase(name) == "authorization"
               end)

        {:ok,
         %Req.Response{
           status: 200,
           body: Jason.encode!(%{"object" => "list", "data" => [model("cached")]}),
           headers: %{}
         }}
      end

      opts = %{cache_dir: directory, request: request}
      assert {:ok, path} = InferenceNet.pull(opts)
      assert File.exists?(path)
      assert {:ok, data} = InferenceNet.load(opts)
      assert [%{id: "cached"}] = data["inference"].models
    end
  end

  defp model(id) do
    %{
      "id" => id,
      "object" => "model",
      "owned_by" => "system",
      "context_length" => 1_040_000,
      "max_completion_tokens" => 393_216,
      "reasoning_efforts" => ~w(none low high max),
      "input_modalities" => ~w(text image),
      "output_modalities" => ["text"],
      "supported_endpoints" => ~w(chat responses messages),
      "pricing" => %{
        "prompt" => "0.000000300000",
        "completion" => "0.000001000000",
        "input_cache_read" => "0.000000007000"
      }
    }
  end
end
