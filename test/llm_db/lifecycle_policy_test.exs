defmodule LLMDB.LifecyclePolicyTest do
  use ExUnit.Case, async: true

  alias LLMDB.Engine.LifecyclePolicy
  alias LLMDB.Model

  test "matches exact offers and retains explicit retirement" do
    assert {:ok, offers} = LifecyclePolicy.read("priv/llm_db/local/deprecated-families.toml")
    assert MapSet.size(offers) == 23

    active = Model.new!(%{provider: :azure, id: "gpt-3.5-turbo-0125"})
    unrelated = Model.new!(%{provider: :azure, id: "gpt-4"})

    retired = %{
      active
      | retired: true,
        deprecated: true,
        lifecycle: %{status: "retired", retires_at: "2025-01-01", replacement: "gpt-4"}
    }

    assert [
             %{deprecated: true, retired: false, lifecycle: %{status: "deprecated"}},
             ^unrelated,
             ^retired
           ] =
             LifecyclePolicy.apply([active, unrelated, retired], offers)
  end
end
