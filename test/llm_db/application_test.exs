defmodule LLMDB.ApplicationTest do
  use ExUnit.Case, async: false

  alias LLMDB.Catalog

  @dotenv_path Path.expand(".env")
  @config_keys [
    :allow,
    :custom,
    :deny,
    :filter,
    :integrity_policy,
    :prefer,
    :skip_packaged_load,
    :snapshot_source
  ]

  setup do
    original_config = Map.new(@config_keys, &{&1, Application.fetch_env(:llm_db, &1)})

    Catalog.clear!()

    on_exit(fn ->
      Catalog.clear!()

      Enum.each(original_config, fn
        {key, {:ok, value}} -> Application.put_env(:llm_db, key, value)
        {key, :error} -> Application.delete_env(:llm_db, key)
      end)
    end)

    :ok
  end

  test "the OTP application starts no llm_db callback, supervisor, or worker" do
    assert Application.spec(:llm_db, :mod) in [nil, []]
    refute Process.whereis(LLMDB.Supervisor)
    refute Process.whereis(LLMDB.Application)
    assert Catalog.snapshot() == nil
  end

  test "the deprecated direct-call shim starts only its former empty supervisor" do
    assert {:ok, supervisor} = apply(LLMDB.Application, :start, [:normal, []])

    try do
      assert Process.whereis(LLMDB.Supervisor) == supervisor
      assert Supervisor.which_children(supervisor) == []
      assert Catalog.snapshot() == nil
    after
      Supervisor.stop(supervisor)
    end
  end

  test "explicit preload prepares the catalog before the first public query" do
    enable_lazy_loading()

    assert Catalog.snapshot() == nil
    assert {:ok, _catalog} = LLMDB.load()
    preload_epoch = Catalog.epoch()

    assert preload_epoch > 0
    assert {:ok, _model} = LLMDB.model("openai:gpt-4o")
    assert Catalog.epoch() == preload_epoch
  end

  test "first query lazily loads once and warm queries do no initialization work" do
    enable_lazy_loading()

    assert Catalog.snapshot() == nil
    assert [_ | _] = providers = LLMDB.providers()
    first_epoch = Catalog.epoch()

    assert first_epoch > 0
    assert LLMDB.providers() == providers
    assert Catalog.epoch() == first_epoch
    refute Process.whereis(LLMDB.Supervisor)
  end

  test "concurrent first queries publish one catalog" do
    enable_lazy_loading()

    parent = self()

    tasks =
      for _ <- 1..16 do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :query -> {length(LLMDB.providers()), Catalog.epoch()}
          end
        end)
      end

    task_pids =
      for _ <- tasks do
        assert_receive {:ready, pid}
        pid
      end

    Enum.each(task_pids, &send(&1, :query))
    results = Task.await_many(tasks, 30_000)

    assert Enum.all?(results, fn {provider_count, _epoch} -> provider_count > 0 end)
    assert results |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == 1
  end

  test "explicit reload is serialized with first-use initialization" do
    enable_lazy_loading()
    parent = self()

    query =
      Task.async(fn ->
        send(parent, {:ready, self()})
        receive do: (:go -> LLMDB.models(:openai))
      end)

    reload =
      Task.async(fn ->
        send(parent, {:ready, self()})
        receive do: (:go -> LLMDB.load(allow: [:openai]))
      end)

    pids =
      for _ <- 1..2 do
        assert_receive {:ready, pid}
        pid
      end

    Enum.each(pids, &send(&1, :go))

    assert [_ | _] = Task.await(query, 30_000)
    assert {:ok, _catalog} = Task.await(reload, 30_000)
    assert [_ | _] = LLMDB.models(:openai)
    assert LLMDB.models(:anthropic) == []
  end

  test "skip_packaged_load leaves lazy queries empty but preserves explicit load" do
    Application.put_env(:llm_db, :skip_packaged_load, true)
    Application.put_env(:llm_db, :snapshot_source, :packaged)

    assert LLMDB.providers() == []
    assert Catalog.snapshot() == nil

    assert {:ok, _catalog} = LLMDB.load()
    assert [_ | _] = LLMDB.providers()
  end

  test "lazy loading applies configured filters and custom models" do
    enable_lazy_loading()

    Application.put_env(:llm_db, :allow, %{lazy_local: :all})

    Application.put_env(:llm_db, :custom, %{
      lazy_local: [
        name: "Lazy Local",
        models: %{"local-model" => %{capabilities: %{chat: true}}}
      ]
    })

    assert {:ok, model} = LLMDB.model(:lazy_local, "local-model")
    assert model.provider == :lazy_local
    assert model.id == "local-model"
    assert model.capabilities.chat == true
    assert LLMDB.models(:openai) == []
  end

  test "strict integrity failures move to first query and explicit load retains tuples" do
    path = mismatched_snapshot_path()

    on_exit(fn -> File.rm(path) end)

    Application.put_env(:llm_db, :skip_packaged_load, false)
    Application.put_env(:llm_db, :snapshot_source, {:file, path})
    Application.put_env(:llm_db, :integrity_policy, :strict)

    error =
      assert_raise LLMDB.LoadError, fn ->
        LLMDB.providers()
      end

    reason = error.reason
    assert reason != nil
    assert {:error, ^reason} = LLMDB.load()
  end

  test "lazy catalog loading does not load the repository dotenv file" do
    key = "LLMDB_RUNTIME_LOAD_MUST_NOT_LOAD_DOTENV"
    original_dotenv = dotenv_file()
    original_env = System.get_env(key)

    try do
      File.write!(@dotenv_path, "#{key}=from_dotenv\n")
      System.delete_env(key)
      enable_lazy_loading()

      assert [_ | _] = LLMDB.providers()
      assert System.get_env(key) == nil
    after
      restore_dotenv_file(original_dotenv)
      restore_system_env(key, original_env)
    end
  end

  defp enable_lazy_loading do
    Application.put_env(:llm_db, :skip_packaged_load, false)
    Application.put_env(:llm_db, :snapshot_source, :packaged)
    Application.put_env(:llm_db, :integrity_policy, :warn)
  end

  defp mismatched_snapshot_path do
    path = Path.join(System.tmp_dir!(), "llm_db-lazy-#{System.unique_integer([:positive])}.json")

    snapshot =
      LLMDB.Packaged.snapshot_path()
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("snapshot_id", "mismatched-snapshot-id")

    File.write!(path, Jason.encode!(snapshot))
    path
  end

  defp dotenv_file do
    case File.read(@dotenv_path) do
      {:ok, contents} -> {:ok, contents}
      {:error, :enoent} -> :missing
    end
  end

  defp restore_dotenv_file({:ok, contents}), do: File.write!(@dotenv_path, contents)
  defp restore_dotenv_file(:missing), do: File.rm(@dotenv_path)

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
