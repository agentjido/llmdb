defmodule LLMDB.ModelMetadataTest do
  use ExUnit.Case, async: true

  import Plug.Conn

  @spec_id {:openrouter, "openai/gpt-3.5-turbo-0613"}

  test "validates display metadata and drops remote execution fields" do
    plug = fn conn ->
      assert conn.request_path == "/api/v1/models/openrouter/openai/gpt-3.5-turbo-0613"

      send_resp(
        conn,
        200,
        envelope(%{
          id: "openai/gpt-3.5-turbo-0613",
          provider: "openrouter",
          modalities: %{input: ["text"]},
          base_url: "https://example.invalid",
          execution: %{text: "invalid"},
          extra: %{secret: "invalid"}
        })
      )
    end

    assert {:ok,
            %LLMDB.Model{
              provider: :openrouter,
              modalities: %{input: [:text]},
              base_url: nil,
              execution: nil,
              extra: nil
            }} =
             LLMDB.fetch_model(@spec_id, plug: plug)
  end

  test "rejects mismatched identity, unsupported documents and oversize bodies" do
    assert {:error, :invalid_model_metadata} =
             LLMDB.fetch_model(@spec_id,
               plug: fn conn ->
                 send_resp(conn, 200, envelope(%{id: "other", provider: "openrouter"}))
               end
             )

    assert {:error, :invalid_model_metadata} =
             LLMDB.fetch_model(@spec_id,
               plug: fn conn -> send_resp(conn, 200, ~s({"schema_version":2})) end
             )

    assert {:error, :response_too_large} =
             LLMDB.fetch_model(@spec_id,
               plug: fn conn -> send_resp(conn, 200, String.duplicate("x", 65_537)) end
             )

    assert {:error, :unknown_provider} = LLMDB.fetch_model({:not_a_catalog_provider, "x"})
  end

  defp envelope(model) do
    Jason.encode!(%{schema_version: 1, snapshot_id: String.duplicate("a", 64), model: model})
  end
end
