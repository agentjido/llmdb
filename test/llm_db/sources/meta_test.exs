defmodule LLMDB.Sources.MetaTest do
  use ExUnit.Case, async: false

  alias LLMDB.{Engine, Source}
  alias LLMDB.Sources.{Config, Local, Meta, Remote}

  @url "https://api.meta.ai/v1/models"

  setup do
    cache_dir = Path.join(System.tmp_dir!(), "llmdb-meta-#{System.unique_integer([:positive])}")
    original_key = System.get_env("MODEL_API_KEY")
    System.delete_env("MODEL_API_KEY")

    on_exit(fn ->
      File.rm_rf!(cache_dir)

      if original_key,
        do: System.put_env("MODEL_API_KEY", original_key),
        else: System.delete_env("MODEL_API_KEY")
    end)

    %{opts: %{cache_dir: cache_dir}, remote_opts: [cache_dir: cache_dir, cache_key: "meta"]}
  end

  test "maps sparse registry fields without inventing release dates or capabilities" do
    raw =
      registry_model("muse-wonder-1.0")
      |> Map.put("metadata", %{"unverified_client" => %{"output_tokens" => 123}})

    data = Meta.transform(%{"data" => [raw]})
    assert Source.assert_canonical!(data) == :ok
    [model] = data["meta"].models
    assert model.id == "muse-wonder-1.0"
    assert model.provider == :meta
    assert model.catalog_only
    assert model.extra == %{created: 1_791_849_600, owned_by: "meta"}

    for field <- [:release_date, :limits, :cost, :capabilities, :execution] do
      refute Map.has_key?(model, field)
    end
  end

  test "excludes Muse Code and subscription-only Wonder Full" do
    models =
      Enum.map(
        ~w(muse-code muse-code-1.0 muse-wonder-full-1.0 muse-wonder-1.0),
        &registry_model/1
      )

    assert [%{id: "muse-wonder-1.0"}] = Meta.transform(%{"data" => models})["meta"].models
  end

  test "missing or empty credentials make no request", ctx do
    request = fn _url, _opts -> flunk("unexpected request") end

    for key <- [nil, ""] do
      opts = Map.merge(ctx.opts, %{api_key: key, req_opts: [request: request]})
      assert {:error, :no_api_key} = Meta.pull(opts)
    end
  end

  test "the pull task accepts --source meta and skips an absent key" do
    original_dotenv = Application.get_env(:llm_db, :load_dotenv)
    Application.put_env(:llm_db, :load_dotenv, false)

    try do
      output =
        ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.LlmDb.Pull.run(["--source", "meta"]) end)

      assert output =~ "LLMDB.Sources.Meta: Skipped (no API key)"
      assert output =~ "0 failed"
    after
      if is_nil(original_dotenv),
        do: Application.delete_env(:llm_db, :load_dotenv),
        else: Application.put_env(:llm_db, :load_dotenv, original_dotenv)
    end
  end

  test "uses bearer authentication and keeps request options for tests", ctx do
    request = fn url, opts ->
      assert url == @url
      assert opts[:headers] == [{"authorization", "Bearer test-key"}, {"x-test", "present"}]
      assert opts[:retry] == false
      assert opts[:decode_body] == false
      response([registry_model("muse-wonder-1.0")])
    end

    opts =
      Map.merge(ctx.opts, %{
        api_key: "test-key",
        req_opts: [request: request, retry: false, headers: [{"x-test", "present"}]]
      })

    assert {:ok, path} = Meta.pull(opts)
    assert File.exists?(path)
    refute File.read!(path) =~ "test-key"
    manifest = path |> String.replace_suffix(".json", ".manifest.json") |> File.read!()
    refute manifest =~ "test-key"
    assert Jason.decode!(manifest)["source_url"] == @url
  end

  test "reads MODEL_API_KEY and lets an explicit key take precedence", ctx do
    System.put_env("MODEL_API_KEY", "environment-key")

    for {extra, expected} <- [
          {%{}, "environment-key"},
          {%{api_key: "explicit-key"}, "explicit-key"}
        ] do
      request = fn _url, opts ->
        assert {"authorization", "Bearer " <> expected} in opts[:headers]
        response([])
      end

      assert {:ok, _path} =
               Meta.pull(Map.merge(ctx.opts, Map.put(extra, :req_opts, request: request)))
    end
  end

  test "loads cached records without credentials or a network request", ctx do
    seed_cache(ctx.remote_opts, [registry_model("muse-wonder-1.0")])
    request = fn _url, _opts -> flunk("load must not make a network request") end

    assert {:ok, data} = Meta.load(Map.put(ctx.opts, :req_opts, request: request))
    assert [%{id: "muse-wonder-1.0"}] = data["meta"].models

    assert {:error, :no_cache} =
             Meta.load(%{cache_dir: ctx.opts.cache_dir, url: "https://example.test/models"})
  end

  test "HTTP failures preserve the last good cache", ctx do
    path = seed_cache(ctx.remote_opts, [registry_model("muse-wonder-1.0")])
    original = File.read!(path)

    for status <- [401, 429, 500] do
      request = fn _url, _opts -> {:ok, %Req.Response{status: status, body: "test-key"}} end

      assert {:error, {:http_status, ^status}} =
               Meta.pull(
                 Map.merge(ctx.opts, %{api_key: "test-key", req_opts: [request: request]})
               )

      assert File.read!(path) == original
    end
  end

  test "transport and response errors do not expose credentials or replace the cache", ctx do
    path = seed_cache(ctx.remote_opts, [registry_model("muse-wonder-1.0")])
    original = File.read!(path)

    for {result, expected} <- [
          {{:error, %{request: %{authorization: "test-key"}}}, :request_failed},
          {{:ok, %Req.Response{status: 200, body: "not-json test-key"}}, :invalid_response},
          {{:ok, %Req.Response{status: 200, body: %{"data" => "invalid"}}}, :invalid_response},
          {{:ok, %Req.Response{status: 200, body: %{"data" => [%{"id" => 123}]}}},
           :invalid_response}
        ] do
      request = fn _url, _opts -> result end

      assert {:error, ^expected} =
               Meta.pull(
                 Map.merge(ctx.opts, %{api_key: "test-key", req_opts: [request: request]})
               )

      assert File.read!(path) == original
    end
  end

  test "team-specific and empty responses preserve previously discovered models", ctx do
    seed_cache(ctx.remote_opts, [
      registry_model("muse-wonder-1.0"),
      registry_model("muse-spark-1.3")
    ])

    latest = Map.put(registry_model("muse-spark-1.3"), "created", 1_791_849_601)

    for models <- [[latest], []] do
      request = fn _url, _opts -> response(models) end

      assert {:ok, _path} =
               Meta.pull(
                 Map.merge(ctx.opts, %{api_key: "test-key", req_opts: [request: request]})
               )

      assert {:ok, data} = Meta.load(ctx.opts)
      assert Enum.map(data["meta"].models, & &1.id) == ["muse-spark-1.3", "muse-wonder-1.0"]
      assert hd(data["meta"].models).extra.created == 1_791_849_601
    end
  end

  test "a cached sparse response preserves reviewed metadata and other catalog models", ctx do
    seed_cache(ctx.remote_opts, [
      registry_model("muse-wonder-1.0"),
      registry_model("unknown-media-model")
    ])

    known = %{id: "muse-spark-1.3", provider: :meta, catalog_only: true}
    unverified = %{id: "muse-wonder-1.0", provider: :meta, limits: %{output: 131_072}}

    assert {:ok, snapshot} =
             Engine.run(
               sources: [
                 {Config, %{overrides: %{meta: %{models: [known, unverified]}}}},
                 {Meta, ctx.opts},
                 {Local, %{dir: "priv/llm_db/local"}}
               ]
             )

    models = snapshot.providers.meta.models
    assert Map.has_key?(models, "muse-spark-1.3")
    assert models["unknown-media-model"].catalog_only
    assert models["unknown-media-model"].execution == nil
    wonder = models["muse-wonder-1.0"]
    refute wonder.catalog_only
    assert wonder.execution.text.family == "openai_responses_compatible"
    assert wonder.execution.object.family == "openai_responses_compatible"
    assert wonder.limits.context == 1_048_576
    refute Map.has_key?(wonder.limits, :output)
    assert wonder.cost == %{input: 4.0, cache_read: 0.2, output: 20.0}
    assert wonder.capabilities.tools.enabled
    assert wonder.capabilities.json.schema
    assert wonder.capabilities.streaming.text
    assert wonder.extra.created == 1_791_849_600
    assert wonder.release_date == "2026-10-12"
  end

  defp registry_model(id),
    do: %{"id" => id, "object" => "model", "created" => 1_791_849_600, "owned_by" => "meta"}

  defp response(models),
    do: {:ok, %Req.Response{status: 200, body: %{"object" => "list", "data" => models}}}

  defp seed_cache(opts, models) do
    {:ok, path} = Remote.store(@url, %{"object" => "list", "data" => models}, opts)
    path
  end
end
