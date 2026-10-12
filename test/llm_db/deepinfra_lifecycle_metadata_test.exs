defmodule LLMDB.DeepinfraLifecycleMetadataTest do
  use ExUnit.Case, async: true

  alias LLMDB.{Model, Normalize}
  alias LLMDB.Sources.Local

  @expected [
    {"zai-org/GLM-4.7-Flash", "2026-09-10T22:32:08Z", "zai-org/GLM-5.3-Flash", "deprecated"},
    {"zai-org/GLM-5.1", "2026-10-01T23:22:37Z", "zai-org/GLM-5.3", "deprecated"},
    {"XiaomiMiMo/MiMo-V2.5", "2026-09-29T21:42:30Z", "XiaomiMiMo/MiMo-V2.6-Flash", "deprecated"},
    {"nvidia/Llama-3.3-Nemotron-Super-49B-v1.5", "2026-07-17T22:38:23Z",
     "nvidia/NVIDIA-Nemotron-3-Ultra-550B-A55B", "deprecated"},
    {"nvidia/Nemotron-3-Nano-30B-A3B", "2026-10-08T23:09:54Z",
     "nvidia/NVIDIA-Nemotron-3.5-Lightning", "deprecated"},
    {"Qwen/Qwen3.8-2.4T-A95B", "2026-10-12T23:48:18Z", "zai-org/GLM-5.3", "active"},
    {"tencent/Hy3", "2026-10-08T23:09:54Z", "tencent/Hy4-preview", "deprecated"},
    {"MiniMaxAI/MiniMax-M2.5", "2026-09-10T22:22:06Z", "MiniMaxAI/MiniMax-M3", "deprecated"},
    {"Qwen/Qwen3.5-122B-A10B", "2026-10-01T23:32:43Z", "Qwen/Qwen3.5-397B-A17B", "deprecated"},
    {"google/gemma-4-E4B-it", "2026-10-01T23:32:46Z", "google/gemma-4-31B-it-turbo",
     "deprecated"},
    {"moonshotai/Kimi-K2.7-Code", "2026-09-29T23:42:55Z", "moonshotai/Kimi-K3", "deprecated"},
    {"deepseek-ai/DeepSeek-V3-0324", "2026-09-29T23:42:50Z", "deepseek-ai/DeepSeek-V4.1-Flash",
     "deprecated"},
    {"moonshotai/Kimi-K2.5", "2026-09-07T23:40:37Z", "moonshotai/Kimi-K2.6", "deprecated"},
    {"nvidia/Nemotron-3-Nano-Omni-30B-A3B-Reasoning", "2026-07-16T23:09:53Z",
     "nvidia/NVIDIA-Nemotron-3-Ultra-550B-A55B", "deprecated"},
    {"XiaomiMiMo/MiMo-V2.5-Pro", "2026-09-29T21:42:31Z", "XiaomiMiMo/MiMo-V2.6-Pro",
     "deprecated"},
    {"MiniMaxAI/MiniMax-M2.7", "2026-09-10T22:22:06Z", "MiniMaxAI/MiniMax-M3", "deprecated"},
    {"Qwen/Qwen3-Max", "2026-10-10T00:00:00Z", "Qwen/Qwen3.8-Max", "deprecated"},
    {"zai-org/GLM-5", "2026-09-10T22:22:06Z", "zai-org/GLM-5.2", "deprecated"},
    {"meta-llama/Llama-4-Maverick-17B-128E-Instruct-FP8", "2026-10-01T23:32:49Z",
     "google/gemma-4-31B-it-turbo", "deprecated"},
    {"stepfun-ai/Step-3.7-Flash", "2026-10-01T23:32:45Z", "XiaomiMiMo/MiMo-V2.6-Flash",
     "deprecated"}
  ]

  test "local and packaged metadata preserve provider deprecation timestamps and replacements" do
    {:ok, local} = Local.load(%{dir: "priv/llm_db/local"})

    overlays =
      local["deepinfra"].models
      |> Normalize.normalize_models()
      |> Map.new(&{&1.id, Model.new!(&1)})

    snapshot = "priv/llm_db/snapshot.json" |> File.read!() |> Jason.decode!()
    packaged = snapshot["providers"]["deepinfra"]["models"]

    for {id, timestamp, replacement, status} <- @expected do
      overlay = overlays[id]

      assert overlay.lifecycle == %{
               status: status,
               deprecated_at: timestamp,
               replacement: replacement
             }

      assert overlay.deprecated == (status == "deprecated")
      refute overlay.retired

      assert packaged[id]["lifecycle"] == %{
               "status" => status,
               "deprecated_at" => timestamp,
               "replacement" => replacement
             }

      assert packaged[id]["deprecated"] == (status == "deprecated")
      refute packaged[id]["retired"]
    end
  end

  test "scheduled deprecation takes effect at the exact UTC timestamp" do
    {:ok, local} = Local.load(%{dir: "priv/llm_db/local"})

    model =
      local["deepinfra"].models
      |> Normalize.normalize_models()
      |> Enum.find(&(&1.id == "Qwen/Qwen3.8-2.4T-A95B"))
      |> Model.new!()

    {:ok, boundary, 0} = DateTime.from_iso8601(model.lifecycle.deprecated_at)
    refute Model.deprecated?(model, DateTime.add(boundary, -1, :second))
    assert Model.deprecated?(model, boundary)
    assert Model.deprecated?(model, DateTime.add(boundary, 1, :second))
    refute Model.retired?(model, boundary)
  end
end
