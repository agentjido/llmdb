defmodule LLMDB.GitHistoryFixtureTest do
  use ExUnit.Case, async: false

  alias LLMDB.Test.GitHistoryFixture

  test "fixture Git commands do not use a parent repository from hook environment" do
    parent = GitHistoryFixture.create!()
    on_exit(fn -> GitHistoryFixture.cleanup(parent) end)
    keys = ~w(GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE)
    previous = Map.new(keys, &{&1, System.get_env(&1)})

    try do
      System.put_env("GIT_DIR", Path.join(parent.repo, ".git"))
      System.put_env("GIT_WORK_TREE", parent.repo)
      System.put_env("GIT_INDEX_FILE", Path.join(parent.repo, ".git/index"))
      child = GitHistoryFixture.create!()
      on_exit(fn -> GitHistoryFixture.cleanup(child) end)

      assert {root, 0} =
               GitHistoryFixture.in_repo(child.repo, fn ->
                 System.cmd("git", ["rev-parse", "--show-toplevel"])
               end)

      assert String.trim(root) == File.cd!(child.repo, &File.cwd!/0)
      assert System.get_env("GIT_DIR") == Path.join(parent.repo, ".git")

      assert {head, 0} =
               System.cmd("git", [
                 "--git-dir",
                 Path.join(parent.repo, ".git"),
                 "rev-parse",
                 "HEAD"
               ])

      assert String.trim(head) == List.last(parent.commits)
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end
end
