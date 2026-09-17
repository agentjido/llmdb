defmodule LLMDB.ExecutionContractTest do
  use ExUnit.Case, async: true

  alias LLMDB.{ExecutionContract, Model, Provider, Validate}

  @cases [
    {"text", %{modalities: %{input: [:text], output: [:text]}}, [:object, :text]},
    {"embeddings", %{modalities: %{input: [:text], output: [:embedding]}}, [:embed]},
    {"image", %{modalities: %{input: [:text], output: [:image]}}, [:image]},
    {"audio transcription", %{modalities: %{input: [:audio], output: [:text]}}, [:transcription]},
    {"audio speech", %{modalities: %{input: [:text], output: [:audio]}}, [:speech]},
    {"video-input chat", %{modalities: %{input: [:text, :video], output: [:text]}},
     [:object, :text]},
    {"tool-using chat", %{capabilities: %{chat: true, tools: %{enabled: true}}}, [:object, :text]}
  ]

  test "enrichment and validation share table-driven operation inference" do
    provider = executable_provider()

    Enum.each(@cases, fn {name, attrs, expected_operations} ->
      model = Model.new!(Map.merge(%{id: name, provider: :openai}, attrs))
      enriched = ExecutionContract.enrich_model(model, provider)

      assert Enum.sort(ExecutionContract.implied_operations(model, provider)) ==
               expected_operations

      assert Enum.sort(Map.keys(enriched.execution)) == expected_operations
      assert :ok = Validate.validate_runtime_contract([provider], [enriched])
    end)
  end

  test "catalog-only providers infer no executable operations" do
    provider =
      Provider.new!(%{id: :catalog_only, catalog_only: true})
      |> ExecutionContract.enrich_provider()

    model = Model.new!(%{id: "docs-only", provider: :catalog_only})
    enriched = ExecutionContract.enrich_model(model, provider)

    assert ExecutionContract.implied_operations(model, provider) == []
    assert enriched.execution == nil
    assert enriched.catalog_only
    assert :ok = Validate.validate_runtime_contract([provider], [enriched])
  end

  test "evaluation-only models derive evaluation execution without generation" do
    provider =
      Provider.new!(%{
        id: :typesafe,
        runtime: %{
          base_url: "https://api.typesafe.ai",
          auth: %{type: "bearer", env: ["TYPESAFE_API_KEY"]},
          execution: %{evaluate: "typesafe_systemone"}
        }
      })
      |> ExecutionContract.enrich_provider()

    model =
      Model.new!(%{
        id: "jev-latest",
        provider: :typesafe,
        capabilities: %{chat: false, evaluate: true, streaming: %{text: false}}
      })

    enriched = ExecutionContract.enrich_model(model, provider)

    assert ExecutionContract.implied_operations(model, provider) == [:evaluate]
    assert enriched.catalog_only == false
    assert enriched.capabilities.evaluate == true
    assert enriched.capabilities.chat == false
    assert enriched.execution.evaluate.family == "typesafe_systemone"
    assert enriched.execution.evaluate.wire_protocol == "typesafe_systemone"
    assert enriched.execution.evaluate.path == "/v1/systemone"
    refute Map.has_key?(enriched.execution, :text)
    refute Map.has_key?(enriched.execution, :object)
    assert :ok = Validate.validate_runtime_contract([provider], [enriched])

    incomplete = %{enriched | execution: %{}}

    assert {:error, {:invalid_runtime_contract, errors}} =
             Validate.validate_runtime_contract([provider], [incomplete])

    assert Enum.any?(
             errors,
             &(&1.error == :missing_execution_entry and &1.operation == :evaluate)
           )
  end

  test "explicit model execution overrides inferred provider and modality defaults" do
    provider = executable_provider()

    model =
      Model.new!(%{
        id: "explicit-responses",
        provider: :openai,
        modalities: %{input: [:text], output: [:text]},
        execution: %{
          text: %{
            family: "openai_responses_compatible",
            wire_protocol: "openai_responses",
            path: "/custom-responses"
          }
        }
      })

    enriched = ExecutionContract.enrich_model(model, provider)

    assert enriched.execution.text.family == "openai_responses_compatible"
    assert enriched.execution.text.path == "/custom-responses"
    assert enriched.execution.text.wire_protocol == "openai_responses"
    assert :ok = Validate.validate_runtime_contract([provider], [enriched])
  end

  test "enrich/2 consumes provider execution policy without publishing it" do
    provider = executable_provider()

    model =
      Model.new!(%{
        id: "chat-model",
        provider: :openai,
        modalities: %{input: [:text], output: [:text]}
      })

    assert {[published_provider], [published_model]} =
             ExecutionContract.enrich([provider], [model])

    refute Map.has_key?(published_provider.runtime, :execution)
    assert published_model.execution.text.family == "openai_chat_compatible"
  end

  test "validation sees provider policy before the publication boundary strips it" do
    provider = executable_provider()

    model =
      Model.new!(%{
        id: "chat-model",
        provider: :openai,
        modalities: %{input: [:text], output: [:text]}
      })

    assert {[validation_provider], [enriched_model]} =
             ExecutionContract.enrich_for_validation([provider], [model])

    assert validation_provider.runtime.execution.object == "openai_chat_compatible"

    incomplete_model = %{
      enriched_model
      | execution: Map.delete(enriched_model.execution, :object)
    }

    assert {:error, {:invalid_runtime_contract, errors}} =
             Validate.validate_runtime_contract([validation_provider], [incomplete_model])

    assert Enum.any?(errors, &(&1.error == :missing_execution_entry and &1.operation == :object))

    published_provider = ExecutionContract.publish_provider(validation_provider)
    refute Map.has_key?(published_provider.runtime, :execution)
  end

  defp executable_provider do
    Provider.new!(%{
      id: :openai,
      env: ["OPENAI_API_KEY"],
      runtime: %{
        base_url: "https://api.openai.com/v1",
        auth: %{type: "bearer"},
        execution: %{
          text: "openai_chat_compatible",
          object: "openai_chat_compatible",
          embed: "openai_embeddings",
          image: "openai_images",
          transcription: "openai_transcription",
          speech: "openai_speech",
          realtime: "openai_realtime"
        }
      }
    })
    |> ExecutionContract.enrich_provider()
  end
end
