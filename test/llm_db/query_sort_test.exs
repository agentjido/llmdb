defmodule LLMDB.QuerySortTest do
  use ExUnit.Case, async: false

  alias LLMDB.{Catalog, Model, Provider}

  setup do
    Catalog.clear!()
    on_exit(&Catalog.clear!/0)

    providers = [
      Provider.new!(%{id: :google_vertex, name: "Google Vertex"}),
      Provider.new!(%{id: :google_vertex_anthropic, name: "Vertex Anthropic"})
    ]

    model =
      Model.new!(%{
        id: "claude-model",
        provider: :google_vertex_anthropic,
        extra: %{llmfit: %{parameters_raw: 10_000_000_000}}
      })

    catalog =
      Catalog.build(providers, [model], [model],
        filters: %{allow: :all, deny: %{}},
        prefer: [:google_vertex],
        loaded_at: "2026-08-11T00:00:00Z",
        digest: "query-sort-test"
      )

    Catalog.put!(catalog, source: :test)
    :ok
  end

  test "sorted candidates preserve the requested provider route" do
    assert LLMDB.candidates(scope: :google_vertex, sort_by: :total_parameters) == [
             {:google_vertex, "claude-model"}
           ]

    assert LLMDB.candidates(sort_by: :total_parameters) == [
             {:google_vertex, "claude-model"},
             {:google_vertex_anthropic, "claude-model"}
           ]
  end

  test "sorted selection preserves the requested provider route" do
    assert LLMDB.select(scope: :google_vertex, sort_by: :total_parameters) ==
             {:ok, {:google_vertex, "claude-model"}}
  end
end
