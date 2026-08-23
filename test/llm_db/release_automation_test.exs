defmodule LLMDB.ReleaseAutomationTest do
  use ExUnit.Case, async: true

  @workflow_path ".github/workflows/release.yml"
  @config_path "config/config.exs"
  @changelog_path "CHANGELOG.md"

  test "publishing starts in a new run at the exact release tag" do
    workflow = File.read!(@workflow_path)

    assert workflow =~ "publish_tag:"
    assert workflow =~ ~s(--ref "$RELEASE_VERSION")
    assert workflow =~ ~s(GITHUB_REF" != "refs/tags/$RELEASE_VERSION)
    assert workflow =~ ~s(GITHUB_SHA" != "$RELEASE_SHA)
    assert workflow =~ "gh run watch"
    refute workflow =~ "repository_dispatch:"
    refute workflow =~ "needs.prepare.outputs"
  end

  test "release preparation is serialized and pushes atomically" do
    workflow = File.read!(@workflow_path)

    assert workflow =~ "group: release-"
    assert workflow =~ "cancel-in-progress: false"
    assert workflow =~ "git push --atomic origin"
    assert workflow =~ "Tests can be skipped only during a dry run."
    refute workflow =~ "git push origin main\n"
  end

  test "publishing can recover an existing immutable release" do
    workflow = File.read!(@workflow_path)

    assert workflow =~ "Hex package $RELEASE_VERSION exists"
    assert workflow =~ "mix hex.publish docs --yes"
    assert workflow =~ ~s(npm view "@agentjido/llmdb@$RELEASE_VERSION")
    assert workflow =~ ~s(gh release view "$RELEASE_VERSION")
  end

  test "publishing verifies public registries and runtimes" do
    workflow = File.read!(@workflow_path)

    assert workflow =~ "verify_release:"
    assert workflow =~ "npm audit signatures --include-attestations"
    assert workflow =~ "verify-npm-provenance.mjs"
    assert workflow =~ "https://hexdocs.pm/llm_db/$RELEASE_VERSION/LLMDB.html"
    assert workflow =~ ~s(node: ["22.14", "24"])
  end

  test "all workflow actions use immutable commits" do
    uses =
      Path.wildcard(".github/workflows/*.yml")
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> then(&Regex.scan(~r/uses:\s+[^@\s]+@([^\s#]+)/, &1, capture: :all_but_first))
      end)
      |> List.flatten()

    assert uses != []
    assert Enum.all?(uses, &Regex.match?(~r/^[a-f0-9]{40}$/, &1))

    ci = File.read!(".github/workflows/ci.yml")
    assert ci =~ "actionlint/cmd/actionlint@v1.7.12"
    assert ci =~ "zizmor==1.29.0"
  end

  test "git_ops reads the previous version from the changelog" do
    config = File.read!(@config_path)

    assert config =~ ~s(version_source: {:file, "CHANGELOG.md")
    assert config =~ ~S|~r/^## \[(\d{4}\.\d+\.\d+)\]/m|
    refute config =~ "version_source: :tags"
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
