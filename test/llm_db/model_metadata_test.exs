defmodule LLMDB.ModelMetadataTest do
  use ExUnit.Case, async: false

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

  test "parses a known string spec without reading or updating the local catalog" do
    LLMDB.Store.clear!()
    assert LLMDB.snapshot() == nil
    id = "openai/gpt-3.5-turbo-0613"
    plug = fn conn -> send_resp(conn, 200, envelope(%{id: id, provider: "openrouter"})) end

    assert {:ok, %LLMDB.Model{id: ^id}} = LLMDB.fetch_model("openrouter:" <> id, plug: plug)
    assert LLMDB.snapshot() == nil
  end

  test "uses the standard HTTP adapter and keeps the complete request within the deadline" do
    with_server(
      fn socket ->
        body = envelope(%{id: "openai/gpt-3.5-turbo-0613", provider: "openrouter"})

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\nconnection: close\r\ncontent-length: ",
            Integer.to_string(byte_size(body)),
            "\r\n\r\n",
            body
          ])
      end,
      fn url ->
        assert {:ok, %LLMDB.Model{provider: :openrouter}} =
                 LLMDB.ModelMetadata.fetch(@spec_id, [timeout: 2_000], url)
      end
    )

    with_server(
      fn _socket ->
        Process.sleep(300)
      end,
      fn url ->
        assert {:error, :timeout} = LLMDB.ModelMetadata.fetch(@spec_id, [timeout: 100], url)
      end
    )
  end

  defp with_server(reply, request) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :http_bin, active: false, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)

    worker =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2_000)

        try do
          case :gen_tcp.recv(socket, 0, 2_000) do
            {:ok, {:http_request, :GET, {:abs_path, _path}, _version}} -> reply.(socket)
            {:error, :closed} -> :ok
          end
        after
          :gen_tcp.close(socket)
        end
      end)

    try do
      request.("http://127.0.0.1:#{port}/api/v1/models")
    after
      Task.await(worker)
      :gen_tcp.close(listener)
    end
  end

  defp envelope(model) do
    Jason.encode!(%{schema_version: 1, snapshot_id: String.duplicate("a", 64), model: model})
  end
end
