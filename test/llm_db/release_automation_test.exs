defmodule LLMDB.ReleaseAutomationTest do
  use ExUnit.Case, async: true

  @workflow_path ".github/workflows/release.yml"
  @config_path "config/config.exs"
  @changelog_path "CHANGELOG.md"

  test "publishing starts in a new run at the release commit" do
    workflow = File.read!(@workflow_path)

    assert workflow =~ "repository_dispatch:"
    assert workflow =~ "publish_release"
    assert workflow =~ "github.event_name == 'repository_dispatch'"
    assert workflow =~ ~s(GITHUB_SHA" != "$RELEASE_SHA)
    assert workflow =~ ~s(TAG_SHA" != "$RELEASE_SHA)
    refute workflow =~ "needs.prepare.outputs"
  end

  test "git_ops reads the previous version from release tags" do
    config = File.read!(@config_path)

    assert config =~ "version_source: :tags"
  end

  test "changelog links compare different tags in the current repository" do
    changelog = File.read!(@changelog_path)

    links =
      Regex.scan(
        ~r/^## \[(?<version>\d{4}\.\d+\.\d+)\]\(https:\/\/github\.com\/agentjido\/llmdb\/compare\/(?<from>.+?)\.\.\.(?<to>[^)]+)\)/m,
        changelog,
        capture: :all_names
      )

    assert links != []

    Enum.each(links, fn [from, to, version] ->
      assert to == version
      refute from == to
    end)

    refute changelog =~ "github.com/agentjido/llm_db/compare/"
  end
end
