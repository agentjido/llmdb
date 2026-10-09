# Sources and Engine

`LLMDB.Engine` is the build-time ETL pipeline. It loads only the sources passed
to it (or returned by `LLMDB.Config.sources!/0`), normalizes and validates their
data, merges the source layers, enriches the result, and emits a canonical
snapshot. Consumer runtime loading is separate: `LLMDB.load/1` reads a packaged
or explicitly configured snapshot, then applies consumer filters and indexes.

## Source Behaviour

Sources implement `LLMDB.Source`:

```elixir
@callback load(opts :: map()) :: {:ok, data :: map()} | {:error, term()}
@callback pull(opts :: map()) ::
            :noop | {:ok, cache_path :: String.t()} | {:error, term()}
```

`pull/1` is optional. Remote sources use it to refresh a local cache; `load/1`
reads that cache and performs no network request.

### Canonical Format

Each outer key is a provider ID string. Its value is a provider map with atom
keys and a `:models` list. Model maps also use atom keys:

```elixir
%{
  "openai" => %{
    id: :openai,
    name: "OpenAI",
    base_url: "https://api.openai.com/v1",
    models: [
      %{
        id: "gpt-4o",
        provider: :openai,
        name: "GPT-4o",
        capabilities: %{chat: true}
      }
    ]
  }
}
```

Use `LLMDB.Source.assert_canonical!/1` for the fast shape assertion. Full Zoi
validation happens in the Engine.

## Built-in Sources

### Remote cached sources

Models.dev, OpenRouter, OpenAI, Anthropic, Google, xAI, ZenMux, LLM API, and Llmfit have
source adapters. Run `mix llm_db.pull` to refresh their repository-local cache;
the Engine subsequently reads that cache through each source's `load/1`.

The LLM API source reads the public `https://api.llmapi.ai/v1/models` catalog.
Run `mix llm_db.pull --source llmapi` to refresh it without credentials, then
`mix llm_db.build --install` to rebuild the packaged snapshot. Runtime loading
does not make network requests.

LLM API model contracts use the shared OpenAI Chat Completions adapter only
when every advertised fallback route supports Chat. Media models and models
with Responses-only routes remain catalog-only. Capabilities are intersected
across fallback routes, and unpublished output limits remain absent. Object
contracts require tools, tool choice, and the `max_tokens` parameter used by
the shared adapter's default object request.

Published one-hour cache-write prices have separate duration-scoped components.
When supported input modalities have different token rates, the source retains
the base `cost` summary and raw fees but excludes the flat `token.input`
component. Complete input pricing then requires a token split by modality;
`extra.pricing_input_split_required` identifies these models.

### Local TOML

```elixir
{LLMDB.Sources.Local, %{dir: "priv/llm_db/local"}}
```

The directory contains one subdirectory per provider. Each provider directory
contains `provider.toml` and model TOML files. The adapter injects the provider
ID from the directory name.

## Configuring Build-time Sources

```elixir
config :llm_db,
  sources: [
    {LLMDB.Sources.ModelsDev, %{}},
    {LLMDB.Sources.Local, %{dir: "priv/llm_db/local"}}
  ]
```

Sources are processed in order and later sources have higher precedence. The
Engine does not implicitly place the packaged runtime snapshot beneath these
sources. Passing no sources produces an empty Engine catalog with a warning;
this does not change the independent runtime default of loading the packaged
snapshot.

## ETL Pipeline

`LLMDB.Engine.run/1` performs these build-time stages:

1. **Ingest** — load configured sources and assert canonical shape.
2. **Normalize** — normalize provider IDs, dates, modalities, and source fields.
3. **Validate** — parse provider/model data with the Zoi schemas.
4. **Merge** — apply last-source-wins precedence and field merge rules.
5. **Finalize** — enrich records and nest models beneath providers.
6. **Ensure viable** — warn when the resulting catalog is empty.

Allow/deny filters, provider preferences, custom runtime overlays, and runtime
indexes are `LLMDB.load/1` concerns, not Engine stages.

## Supported Maintainer Tasks

- `mix llm_db.pull` — fetch and cache upstream source data.
- `mix llm_db.build` — run ETL and build canonical snapshot artifacts.
- `mix llm_db.snapshot.publish` — publish an immutable snapshot release.

These tasks are maintainer tooling. Downstream applications consume the
snapshot shipped with the package.

## Custom Source Example

```elixir
defmodule MyApp.InternalModels do
  @behaviour LLMDB.Source

  @impl true
  def load(_opts) do
    {:ok,
     %{
       "internal" => %{
         id: :internal,
         name: "Internal",
         models: [
           %{
             id: "custom-gpt",
             provider: :internal,
             capabilities: %{chat: true}
           }
         ]
       }
     }}
  end
end

config :llm_db, sources: [{MyApp.InternalModels, %{}}]
```

Custom sources are supported build-time extensions. Their output contract is
stable, while Engine implementation modules are internal and may change behind
that contract.
