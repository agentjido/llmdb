defmodule LLMDB.Sources.LLMAPITest do
  use ExUnit.Case, async: true

  alias LLMDB.{Model, Source}
  alias LLMDB.Sources.{LLMAPI, Remote}

  @url "https://api.llmapi.ai/v1/models"

  describe "transform/1" do
    test "keeps exact gateway IDs, public token rates and documented Chat operations" do
      source =
        chat("vendor/MixedCase:version")
        |> Map.merge(%{
          "aliases" => ["vendor/alias", "vendor/alias", nil],
          "released_at" => "2026-04-30",
          "pricing" => %{
            "prompt" => "0.00000015",
            "completion" => "0.0000006",
            "input_cache_read" => "0.000000075",
            "web_search" => "0.01"
          }
        })

      result = LLMAPI.transform(%{"data" => [source]})
      assert :ok = Source.assert_canonical!(result)
      [model] = result["llmapi"].models
      assert model.id == "vendor/MixedCase:version"
      assert model.provider == :llmapi
      refute Map.has_key?(model, :provider_model_id)
      assert model.aliases == ["vendor/alias"]
      assert model.release_date == "2026-04-30"
      assert model.cost == %{input: 0.15, output: 0.6, cache_read: 0.075}
      assert model.extra.unmapped_pricing == %{"web_search" => "0.01"}
      assert model.extra.source_url == @url

      assert model.extra.upstream_models == [
               %{"providerId" => "upstream", "modelName" => "different-upstream-api-id"}
             ]

      assert model.limits == %{context: 128_000}
      assert Enum.sort(Map.keys(model.execution)) == [:object, :text]

      for operation <- [:text, :object] do
        assert model.execution[operation] == %{
                 supported: true,
                 family: "openai_chat_compatible",
                 wire_protocol: "openai_chat",
                 path: "/chat/completions"
               }
      end

      refute model.catalog_only
      refute model.capabilities.json.strict
      refute model.capabilities.tools.strict
      refute model.capabilities.tools.streaming
      refute model.capabilities.streaming.tool_calls
      assert {:ok, _model} = Model.new(model)
    end

    test "mixed protocols and non-chat models remain descriptive catalog entries" do
      mixed =
        Map.put(chat("mixed"), "providers", [route(), Map.put(route(), "responsesOnly", true)])

      responses =
        Map.put(chat("responses"), "providers", [Map.put(route(), "responsesOnly", true)])

      image = chat("image-model") |> Map.put("kind", "image")
      unknown = Map.delete(chat("unknown-kind"), "kind")

      models = LLMAPI.transform(%{"data" => [mixed, responses, image, unknown]})["llmapi"].models
      assert Enum.map(models, & &1.id) == ~w(mixed responses image-model unknown-kind)

      for model <- models do
        assert model.catalog_only
        refute Map.has_key?(model, :execution)
        assert {:ok, canonical} = Model.new(model)
        refute canonical.capabilities.streaming.tool_calls
      end

      refute Map.has_key?(Enum.at(models, 2), :cost)
      refute Enum.at(models, 2).capabilities.chat
      refute Enum.at(models, 3).capabilities.chat
      assert Enum.at(models, 2).extra.pricing == image["pricing"]
    end

    test "Responses-only Chat descriptors retain published capabilities and limits" do
      source =
        Map.put(chat("responses-only"), "providers", [Map.put(route(), "responsesOnly", true)])

      [model] = transform(source)
      assert {:ok, canonical} = Model.new(model)
      assert canonical.catalog_only
      assert canonical.capabilities.chat
      assert canonical.capabilities.streaming.text
      assert canonical.capabilities.tools.enabled
      refute canonical.capabilities.tools.streaming
      assert canonical.limits.context == 128_000
      assert canonical.modalities == %{input: [:text], output: [:text]}
      assert canonical.execution == nil
      refute Map.has_key?(model, :execution)
    end

    test "media descriptors preserve typed image and video outputs without chat defaults" do
      for {kind, output} <- [{"image", :image}, {"video", :video}] do
        raw =
          chat("#{kind}-model")
          |> Map.put("kind", kind)
          |> Map.put("architecture", %{
            "input_modalities" => ["text", "unknown-modality", %{"unexpected" => true}],
            "output_modalities" => [Atom.to_string(output)]
          })

        [model] = transform(raw)
        assert {:ok, canonical} = Model.new(model)
        assert canonical.catalog_only
        refute canonical.capabilities.chat
        refute canonical.capabilities.streaming.text
        refute canonical.capabilities.tools.streaming
        assert canonical.modalities == %{input: [:text], output: [output]}
        assert canonical.extra[:architecture] == raw["architecture"]
        assert canonical.execution == nil
      end
    end

    test "capabilities cannot be assembled from different upstream routes" do
      first =
        Map.merge(route(), %{
          "streaming" => true,
          "tools" => false,
          "json_output" => true,
          "structured_outputs" => false
        })

      second =
        Map.merge(route(), %{
          "streaming" => false,
          "tools" => true,
          "json_output" => false,
          "structured_outputs" => true
        })

      [model] = transform(Map.put(chat("split"), "providers", [first, second]))

      refute model.capabilities.streaming.text
      refute model.capabilities.tools.enabled
      refute model.capabilities.json.native
      refute model.capabilities.json.schema
      assert Map.keys(model.execution) == [:text]
    end

    test "object generation requires tools and tool choice, not native JSON Schema" do
      without_choice =
        Map.put(chat("no-choice"), "supported_parameters", [
          "tools",
          "max_tokens",
          "response_format"
        ])

      tool_only =
        Map.put(chat("tool-only"), "providers", [Map.put(route(), "structured_outputs", false)])

      [without_choice, tool_only] =
        LLMAPI.transform(%{"data" => [without_choice, tool_only]})["llmapi"].models

      assert without_choice.capabilities.json.schema
      refute Map.has_key?(without_choice.execution, :object)
      refute tool_only.capabilities.json.schema
      assert tool_only.execution.object.supported
      refute tool_only.capabilities.tools.forced_choice
    end

    test "object defaults cannot send an undocumented max_tokens parameter" do
      source =
        Map.put(
          chat("no-max-tokens"),
          "supported_parameters",
          ~w(tools tool_choice response_format)
        )

      [model] = transform(source)
      assert model.execution.text.supported
      assert model.capabilities.tools.enabled
      refute Map.has_key?(model.execution, :object)
    end

    test "context and modalities do not overstate any fallback route" do
      source =
        chat("fallback")
        |> Map.put("context_length", 1_000_000)
        |> Map.put("architecture", %{
          "input_modalities" => ["text", "image", "audio", "video"],
          "output_modalities" => ["text"]
        })
        |> Map.put("providers", [
          Map.merge(route(), %{
            "contextSize" => 512_000,
            "vision" => true,
            "audio_input" => true,
            "video_input" => true
          }),
          Map.merge(route(), %{
            "contextSize" => 128_000,
            "vision" => false,
            "audio_input" => false,
            "video_input" => false
          })
        ])

      [model] = transform(source)
      assert model.limits == %{context: 128_000}
      assert model.extra.reported_context_length == 1_000_000
      assert model.modalities == %{input: [:text], output: [:text]}
      assert model.extra.reported_modalities == source["architecture"]
    end

    test "an unknown route context or capability is not treated as confirmed support" do
      uncertain =
        route() |> Map.delete("contextSize") |> Map.delete("streaming") |> Map.delete("tools")

      [model] = transform(Map.put(chat("uncertain"), "providers", [route(), uncertain]))
      refute Map.has_key?(model, :limits)
      assert model.extra.reported_context_length == 128_000
      refute model.capabilities.streaming.text
      refute model.capabilities.tools.enabled
      refute Map.has_key?(model.execution, :object)
    end

    test "zero prices are valid while blanks, malformed rates and output limits are omitted" do
      for price <- ["0", 0, 0.0] do
        [model] =
          transform(Map.put(chat("zero"), "pricing", %{"prompt" => price, "completion" => price}))

        assert model.cost == %{input: 0.0, output: 0.0}
      end

      for price <- ["", "garbage", "0.01 trailing", "1e308", -1, "-0.001", nil, []] do
        source =
          chat("unknown-price")
          |> Map.put("free", true)
          |> Map.put("pricing", %{"prompt" => price, "completion" => price})

        [model] = transform(source)
        refute Map.has_key?(model, :cost)
        refute model.catalog_only
        assert model.extra.free
        refute Map.has_key?(model.limits, :output)
      end
    end

    test "malformed entries cannot accidentally become executable or create atoms" do
      invalid_route = Map.put(chat("bad-route"), "providers", ["not-a-route"])

      invalid_fields =
        Map.merge(chat("bad-fields"), %{
          "providers" => nil,
          "pricing" => [],
          "architecture" => false,
          "supported_parameters" => 1
        })

      data = [nil, false, %{}, %{"id" => ""}, %{"id" => 42}, invalid_route, invalid_fields]
      models = LLMAPI.transform(%{"data" => data})["llmapi"].models
      assert Enum.map(models, & &1.id) == ~w(bad-route bad-fields)
      assert Enum.all?(models, & &1.catalog_only)

      for content <- [nil, [], %{}, %{"data" => %{}}] do
        assert LLMAPI.transform(content)["llmapi"].models == []
      end
    end

    test "lifecycle dates retain future schedules without prematurely retiring models" do
      active =
        Map.merge(chat("scheduled"), %{
          "deprecated_at" => "2099-01-01",
          "deactivated_at" => "2099-02-01T00:00:00Z"
        })

      retired =
        Map.merge(chat("retired"), %{
          "deprecated_at" => "2020-01-01",
          "deactivated_at" => "2020-02-01T00:00:00Z"
        })

      [active, retired] = LLMAPI.transform(%{"data" => [active, retired]})["llmapi"].models
      refute active.deprecated
      refute active.retired

      assert active.lifecycle == %{
               status: "active",
               deprecated_at: "2099-01-01",
               retires_at: "2099-02-01T00:00:00Z"
             }

      assert retired.deprecated
      assert retired.retired
      assert retired.catalog_only
      refute Map.has_key?(retired, :execution)
    end
  end

  describe "explicit pull and offline load" do
    setup do
      directory =
        Path.join(System.tmp_dir!(), "llmapi-source-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(directory) end)
      %{directory: directory}
    end

    test "loads only a local cache and reports missing or malformed cached data", %{
      directory: directory
    } do
      request = fn _url, _opts -> flunk("load/1 must not perform a network request") end
      opts = %{cache_dir: directory, request: request}
      assert {:error, :no_cache} = LLMAPI.load(opts)

      assert {:ok, _path} =
               Remote.store(@url, %{"unexpected" => []},
                 cache_dir: directory,
                 cache_key: "llmapi"
               )

      assert {:error, :invalid_catalog} = LLMAPI.load(opts)
    end

    test "public pull requires no key and writes a reusable offline cache", %{
      directory: directory
    } do
      request = fn url, opts ->
        assert url == @url

        refute Enum.any?(opts[:headers], fn {name, _value} ->
                 String.downcase(name) == "authorization"
               end)

        send(self(), :pulled)

        {:ok,
         %Req.Response{
           status: 200,
           body: Jason.encode!(%{"data" => [chat("cached")]}),
           headers: %{}
         }}
      end

      assert {:ok, path} = LLMAPI.pull(%{cache_dir: directory, request: request})
      assert_receive :pulled
      assert File.exists?(String.replace_suffix(path, ".json", ".manifest.json"))

      assert {:ok, data} =
               LLMAPI.load(%{
                 cache_dir: directory,
                 request: fn _, _ -> flunk("unexpected network") end
               })

      assert [model] = data["llmapi"].models
      assert model.id == "cached"
    end

    test "pull reports HTTP failures rather than presenting stale data as a refresh", %{
      directory: directory
    } do
      assert {:ok, path} =
               Remote.store(@url, %{"data" => [chat("cached")]},
                 cache_dir: directory,
                 cache_key: "llmapi"
               )

      original = File.read!(path)
      request = fn _url, _opts -> {:ok, %Req.Response{status: 401}} end

      assert {:error, {:http_status, 401}} =
               LLMAPI.pull(%{cache_dir: directory, request: request})

      assert File.read!(path) == original
      assert {:ok, data} = LLMAPI.load(%{cache_dir: directory})
      assert [%{id: "cached"}] = data["llmapi"].models
    end
  end

  defp transform(model), do: LLMAPI.transform(%{"data" => [model]})["llmapi"].models

  defp chat(id) do
    %{
      "id" => id,
      "name" => id,
      "kind" => "chat",
      "context_length" => 128_000,
      "pricing" => %{"prompt" => "0.0000001", "completion" => "0.0000002"},
      "architecture" => %{"input_modalities" => ["text"], "output_modalities" => ["text"]},
      "providers" => [route()],
      "supported_parameters" => ["tools", "tool_choice", "max_tokens", "response_format"]
    }
  end

  defp route do
    %{
      "providerId" => "upstream",
      "modelName" => "different-upstream-api-id",
      "contextSize" => 128_000,
      "streaming" => true,
      "tools" => true,
      "vision" => false,
      "reasoning" => false,
      "json_output" => true,
      "structured_outputs" => true,
      "parallelToolCalls" => false,
      "pricing" => %{"prompt" => "0.0001", "completion" => "0.0002"}
    }
  end
end
