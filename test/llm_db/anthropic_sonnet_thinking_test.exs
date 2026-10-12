defmodule LLMDB.AnthropicSonnetThinkingTest do
  use ExUnit.Case, async: true

  test "packaged Sonnet 5.5 exposes between_tools and its effort restrictions" do
    snapshot = "priv/llm_db/snapshot.json" |> File.read!() |> Jason.decode!()
    models = snapshot["providers"]["anthropic"]["models"]
    model = models["claude-sonnet-5-5"]
    thinking = model["capabilities"]["reasoning"]["thinking"]
    assert thinking["types"] == ["adaptive", "between_tools"]
    assert thinking["default_type"] == "adaptive"
    assert thinking["disable_supported"]
    types = model["extra"]["provider_capabilities"]["thinking"]["types"]
    assert types["between_tools"]["supported"]
    refute types["disabled"]["supported"]
    refute types["enabled"]["supported"]
    constraints = model["extra"]["thinking_constraints"]["between_tools"]
    assert constraints["effort_values"] == ["low", "medium", "high"]
    refute constraints["additional_fields_supported"]
    refute constraints["per_message_effort_changes_supported"]

    for id <- ["claude-opus-5-5", "claude-haiku-5-5"] do
      types = get_in(models[id], ["capabilities", "reasoning", "thinking", "types"]) || []
      refute "between_tools" in types
    end
  end
end
