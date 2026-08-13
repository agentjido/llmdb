defmodule LLMDB.ColdStartTest do
  use ExUnit.Case, async: false

  test "a fresh VM resolves a packaged string provider on first lookup" do
    ebin_paths =
      Mix.Project.build_path()
      |> Path.join("lib/*/ebin")
      |> Path.wildcard()

    assert ebin_paths != [], "test build has no ebin paths"

    script = """
    if not is_nil(LLMDB.snapshot()) do
      raise "fresh VM loaded the catalog before first lookup"
    end

    {:ok, model} = LLMDB.model("openai:gpt-4o")

    if model.provider != :openai do
      raise "first lookup returned the wrong provider"
    end

    if is_nil(LLMDB.snapshot()) do
      raise "first lookup did not load the catalog"
    end

    IO.puts("cold-string-lookup-ok")
    """

    args = Enum.flat_map(ebin_paths, &["-pa", &1]) ++ ["-e", script]
    elixir = System.find_executable("elixir") || flunk("elixir executable was not found")

    {output, status} =
      System.cmd(elixir, args,
        cd: File.cwd!(),
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "cold-string-lookup-ok"
  end
end
