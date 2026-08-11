# LLM DB - A LLM Model Metadata Database

[![Hex.pm](https://img.shields.io/hexpm/v/llm_db.svg)](https://hex.pm/packages/llm_db)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/llm_db/)
[![CI](https://github.com/agentjido/llm_db/actions/workflows/ci.yml/badge.svg)](https://github.com/agentjido/llm_db/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/llm_db.svg)](https://github.com/agentjido/llm_db/blob/main/LICENSE)
[![Website](https://img.shields.io/badge/website-jido.run-0f172a.svg)](https://jido.run)
[![Ecosystem](https://img.shields.io/badge/ecosystem-jido.run-0ea5e9.svg)](https://jido.run/ecosystem)
[![Discord](https://img.shields.io/badge/discord-join-5865F2.svg?logo=discord&logoColor=white)](https://jido.run/discord)

LLM model metadata catalog with fast, capability-aware lookups. Use simple `"provider:model"` or `"model@provider"` specs, get validated Provider/Model structs, and select models by capabilities. Ships with a packaged snapshot; no network required by default.

The packaged catalog loads lazily on the first query and starts no llm_db
supervisor or worker. To keep catalog preparation outside the first request,
call `LLMDB.load/0` from your application startup. Loading never pulls provider
metadata or reads dotenv files.

- **Primary interface**: `model_spec` — a string like `"openai:gpt-4o-mini"` or `"gpt-4o-mini@openai"` (filename-safe)
- **Fast O(1) reads** via `:persistent_term`
- **Minimal dependencies** 

## Why?

LLM model metadata changes constantly. Providers launch new models, rename aliases,
retire previews, change pricing, add modalities, and expose new runtime
capabilities without waiting for downstream libraries to catch up.

LLM DB gives that moving catalog a refreshable snapshot pattern: pull upstream
metadata, validate and normalize it, package it into releases, and let consumers
query a stable local database at runtime. The site at [llmdb.xyz](https://llmdb.xyz)
showcases the live catalog and makes those ongoing changes easier to inspect.

## Runtime Metadata Contract

`LLMDB` now distinguishes between descriptive catalog metadata and typed execution
metadata.

- `LLMDB.Provider.runtime` declares provider-wide execution defaults such as
  `base_url`, auth strategy, default headers/query params, config schema, and
  runtime docs
- `LLMDB.Model.execution` declares operation-specific support and the canonical
  API family used to execute that operation
- `catalog_only: true` marks packaged entries that are intentionally
  non-executable

Legacy fields like `base_url`, `doc`, and `extra` remain available during
migration, but `runtime` and `execution` are the intended source of truth for
downstream runtime consumers.

The packaged snapshot is enriched at build time:

- providers with a stable runtime contract gain typed `runtime` metadata
- models with a safe canonical execution lane gain typed `execution` metadata
- remaining packaged entries are marked `catalog_only: true` rather than
  forcing downstream consumers to guess

## Installation


### Igniter Installation
If your project has [Igniter](https://hexdocs.pm/igniter/readme.html) available, 
you can install LLM DB using the command 

```bash
mix igniter.install llm_db
```

### Manual Installation
Model metadata is refreshed regularly, so versions follow [CalVer](https://calver.org/) (`YYYY.M.Patch` with no leading zeros):

```elixir
def deps do
  [
    {:llm_db, "~> 2025.11.0"}
  ]
end
```

## model_spec (the main interface)

A `model_spec` is a string in one of two formats:
- `"provider:model"` (e.g., `"openai:gpt-4o-mini"`) — traditional colon format
- `"model@provider"` (e.g., `"gpt-4o-mini@openai"`) — filename-safe format

Both formats are automatically recognized and work interchangeably. Use the `@` format when model specs appear in filenames, CI artifact names, or other filesystem contexts where colons are problematic.

Model lookup and parsing also accept tuples such as `{:provider_atom, "id"}` and `{"provider-id", "id"}`, but prefer the string spec. String provider IDs are normalized to the canonical provider atom.

```elixir
{:ok, model} = LLMDB.model("openai:gpt-4o-mini")
#=> %LLMDB.Model{id: "gpt-4o-mini", provider: :openai, ...}

{:ok, model} = LLMDB.model("gpt-4o-mini@openai")
#=> %LLMDB.Model{id: "gpt-4o-mini", provider: :openai, ...}
```

## Quick Start

```elixir
# Get a model and read metadata
{:ok, model} = LLMDB.model("openai:gpt-4o-mini")
model.capabilities.tools.enabled  #=> true
model.cost.input                  #=> 0.15  (per 1M tokens)
model.limits.context              #=> 128_000

# Model aliases auto-resolve to canonical IDs
{:ok, model} = LLMDB.model("anthropic:claude-haiku-4.5")
model.id  #=> "claude-haiku-4-5-20251001" (canonical ID)

# Select a model by capabilities (returns {provider, id})
{:ok, {provider, id}} = LLMDB.select(
  require: [chat: true, tools: true, json_native: true],
  prefer:  [:openai, :anthropic]
)
{:ok, model} = LLMDB.model({provider, id})

# Sort model candidates by hardware-relevant model size
smallest_models = LLMDB.candidates(
  sort_by: :total_parameters,
  sort_order: :asc
)

# List providers
LLMDB.providers()
#=> [%LLMDB.Provider{id: :anthropic, ...}, %LLMDB.Provider{id: :openai, ...}]

# Check availability (allow/deny filters)
LLMDB.allowed?("openai:gpt-4o-mini") #=> true
```

## API Cheatsheet

- **`model/1`** — `"provider:model"`, `"model@provider"`, `{:provider, id}`, or `{"provider", id}` → `{:ok, %Model{}}` | `{:error, _}`
- **`model/2`** — `provider` atom + `id` → `{:ok, %Model{}}` | `{:error, _}`
- **`models/0`** — list all models → `[%Model{}]`
- **`models/1`** — list provider's models → `[%Model{}]`
- **`providers/0`** — list all providers → `[%Provider{}]`
- **`provider/1`** — get provider by ID → `{:ok, %Provider{}}` | `:error`
- **`select/1`** — pick first match by capabilities → `{:ok, {provider, id}}` | `{:error, :no_match}`
- **`candidates/1`** — get all matches by capabilities → `[{provider, id}]`
- **`capabilities/1`** — get capabilities map → `map()` | `nil`
- **`allowed?/1`** — check availability → `boolean()`
- **`parse/1,2`** — parse spec string (both formats) → `{:ok, {provider, id}}` | `{:error, _}`
- **`parse!/1,2`** — parse spec string, raising on error → `{provider, id}`
- **`format/1,2`** — format `{provider, id}` as string → `"provider:model"` or `"model@provider"`
- **`build/1,2`** — build spec string from input, converting between formats → `String.t()`
- **`load/1`**, **`load/0`** — load or reload snapshot with optional runtime overrides
- **`load_empty/1`** — load empty catalog (fallback when no snapshot available)
- **`epoch/0`**, **`snapshot/0`** — diagnostics
- **`LLMDB.History.available?/0`** — history files available in runtime
- **`LLMDB.History.meta/0`** — history metadata (`meta.json`)
- **`LLMDB.History.timeline/2`** — lineage-aware events for one model
- **`LLMDB.History.recent/1`** — most recent events globally (capped)

See the full function docs in [hexdocs](https://hexdocs.pm/llm_db).

## Data Structures

### Provider

```elixir
%LLMDB.Provider{
  id: :openai,
  name: "OpenAI",
  base_url: "https://api.openai.com",
  env: ["OPENAI_API_KEY"],
  doc: "https://platform.openai.com/docs",
  runtime: %{
    base_url: "https://api.openai.com/v1",
    auth: %{type: "bearer", env: ["OPENAI_API_KEY"]},
    default_headers: %{},
    default_query: %{},
    config_schema: [],
    doc_url: "https://platform.openai.com/docs/api-reference"
  },
  catalog_only: false,
  extra: %{}
}
```

### Model

```elixir
%LLMDB.Model{
  id: "gpt-4o-mini",
  provider: :openai,
  name: "GPT-4o mini",
  family: "gpt-4o",
  doc_url: "https://platform.openai.com/docs/models/gpt-4o-mini",
  limits: %{context: 128_000, output: 16_384},
  cost: %{input: 0.15, output: 0.60},
  capabilities: %{
    chat: true,
    tools: %{enabled: true, streaming: true},
    json: %{native: true, schema: true},
    streaming: %{text: true, tool_calls: true}
  },
  execution: %{
    text: %{supported: true, family: "openai_chat_compatible"},
    object: %{supported: true, family: "openai_chat_compatible"},
    embed: nil,
    image: nil,
    transcription: nil,
    speech: nil,
    realtime: nil
  },
  catalog_only: false,
  tags: [],
  deprecated?: false,
  aliases: [],
  extra: %{}
}
```

## Configuration

The packaged snapshot loads automatically on the first query. Optional runtime filters, preferences, and custom providers:

```elixir
# config/runtime.exs
config :llm_db,
  filter: %{
    allow: :all,                     # :all or %{provider => [patterns]}
    deny: %{openai: ["*-preview"]}   # deny patterns override allow
  },
  prefer: [:openai, :anthropic],     # provider preference order
  custom: %{
    vllm: [
      name: "Local vLLM Provider",
      base_url: "http://localhost:8000/v1",
      models: %{
        "llama-3" => %{capabilities: %{chat: true}},
        "mistral-7b" => %{capabilities: %{chat: true, tools: %{enabled: true}}}
      }
    ]
  }
```

### Preload Before Requests

Lazy loading keeps normal application startup small. If the first request must
not pay the catalog preparation cost, preload the catalog in your consumer
application before you start its supervision tree:

```elixir
def start(_type, _args) do
  with {:ok, _snapshot} <- LLMDB.load() do
    MyApp.Supervisor.start_link(name: MyApp.Supervisor)
  end
end
```

This is opt-in. It uses the same configured snapshot, filters, and custom data
as lazy loading. Do not call the deprecated `LLMDB.Application` compatibility
module directly.

**Runtime environment:** Starting or querying LLM DB never reads a host `.env`
file. Applications own their runtime configuration and may use Dotenvy, direnv,
or another mechanism before starting dependencies.

The maintainer-only `mix llm_db.pull` task loads the repository-local `.env`
before contacting upstream providers. These settings apply only to that task:

```elixir
config :llm_db,
  load_dotenv: true,       # set false to skip .env during metadata pulls
  dotenv_override: true   # repo credentials override the maintainer shell
```

### Filter Examples

```elixir
# Allow all, deny preview/beta models
config :llm_db,
  filter: %{
    allow: :all,
    deny: %{openai: ["*-preview", "*-beta"]}
  }

# Allow only specific model families
config :llm_db,
  filter: %{
    allow: %{
      anthropic: ["claude-3-haiku-*", "claude-3.5-sonnet-*"],
      openrouter: ["anthropic/claude-*"]
    },
    deny: %{}
  }

# Runtime override (widen/narrow filters without rebuild)
{:ok, _snapshot} = LLMDB.load(
  allow: %{openai: ["gpt-4o-*"]},
  deny: %{}
)
```

**Important:** Filters match against **canonical model IDs only**, not aliases. Use canonical IDs (typically dated versions like `claude-haiku-4-5-20251001`) in filter patterns. Aliases are resolved during model lookup, after filtering is applied.

### Custom Providers

Add local or private models to the catalog:

```elixir
# config/runtime.exs
config :llm_db,
  custom: %{
    # Provider ID as key
    vllm: [
      name: "Local vLLM Provider",
      base_url: "http://localhost:8000/v1",
      env: ["OPENAI_API_KEY"],
      doc: "https://docs.vllm.ai",
      models: %{
        "llama-3-8b" => %{
          name: "Llama 3 8B",
          family: "llama-3",
          capabilities: %{chat: true, tools: %{enabled: true}},
          limits: %{context: 8192, output: 2048},
          cost: %{input: 0.0, output: 0.0}
        },
        "mistral-7b" => %{
          capabilities: %{chat: true}
        }
      }
    ],
    myprovider: [
      name: "My Custom Provider",
      models: %{
        "custom-model" => %{capabilities: %{chat: true}}
      }
    ]
  }

# Use custom models like any other
{:ok, model} = LLMDB.model("vllm:llama-3-8b")
{:ok, {provider, id}} = LLMDB.select(require: [chat: true], prefer: [:vllm, :openai])
```

If you use LLMDB with ReqLLM, use a provider ID that ReqLLM supports (for local OpenAI-compatible servers, use `:vllm`) or register your own ReqLLM provider module for custom IDs like `:local`.

**Filter Rules:**
- Provider keys: atoms or strings; patterns: `"*"` (glob) and `~r//` (Regex)
- Deny wins over allow
- Unknown providers are warned and ignored
- Empty allow map `%{}` behaves like `:all`
- `allow: %{provider: []}` blocks provider entirely

See [Runtime Filters guide](guides/runtime-filters.md) for details and troubleshooting.

## Updating Model Data

Snapshot is shipped with the library. To rebuild with fresh data:

```bash
# Fetch upstream data (optional)
mix llm_db.pull

# Build canonical snapshot artifacts
mix llm_db.build

# Install the packaged snapshot for local runtime/package validation
mix llm_db.build --install
```

Snapshot schema v1 remains the packaged and published default. To evaluate the
versioned sparse v2 representation side by side without installing it:

```bash
mix llm_db.build --schema-version 2
```

See [Snapshot Formats and Sparse v2 Rollout](guides/snapshot-formats.md) for the
encoding rules, compatibility contract, measured sizes, and rollout gate.

### Maintained history workflow

Migrate legacy Git-tracked metadata history into the snapshot store once:

```bash
mix llm_db.history.migrate_git --publish
```

This writes snapshot-based history artifacts under `priv/llm_db/history/` and
materializes immutable historical snapshots under
`_build/llm_db/snapshot_store/snapshots/`. With `--publish`, it also seeds the
immutable snapshot releases and publishes the rebuilt history bundle.

After that one-time migration, publish each current snapshot and rebuild history
from the published snapshot observation chain:

```bash
mix llm_db.snapshot.publish
mix llm_db.history.rebuild --publish
mix llm_db.history.sync
mix llm_db.history.check
mix llm_db.history.check --allow-outdated
```

`mix llm_db.history.backfill` and `LLMDB.History.Backfill` remain functional for
compatibility but are deprecated. They may be removed no earlier than
`v2027.0.0`, after at least one minor release deprecation window.

For exceptional spec migrations (renames/provider moves that inference cannot match),
add optional lineage overrides in `priv/llm_db/history/lineage_overrides.json`:

```json
{
  "schema_version": 1,
  "lineage": {
    "openai:gpt-4.1": "openai:gpt-4o"
  }
}
```

History artifacts remain optional local/published data.
Hex packages still only ship `priv/llm_db/snapshot.json`.

See the [Sources & Engine](guides/sources-and-engine.md) guide for details.

## Using with ReqLLM

Designed to power [ReqLLM](https://github.com/agentjido/req_llm), but fully standalone. Use `model_spec` + `model/1` to retrieve metadata for API calls.

Important: LLMDB custom provider IDs do not automatically create ReqLLM providers.
- For local OpenAI-compatible servers, use `:vllm`.
- For arbitrary provider IDs (for example `:local`), register a ReqLLM provider module:

```elixir
defmodule MyApp.ReqLLM.Providers.Local do
  use ReqLLM.Provider,
    id: :local,
    default_base_url: "http://localhost:8080/v1",
    default_env_key: "OPENAI_API_KEY"

  use ReqLLM.Provider.Defaults

  @provider_schema []
end

# config/config.exs
config :req_llm, custom_providers: [MyApp.ReqLLM.Providers.Local]
```

## Contributing

### Setup

```bash
mix setup  # Install dependencies and git hooks
```

### Git Hooks

This project uses [git_hooks](https://hex.pm/packages/git_hooks) to enforce code quality. Hooks install automatically on `mix compile` in dev:

| Hook | Action |
|------|--------|
| **commit-msg** | Validates [conventional commit](https://www.conventionalcommits.org/) format |
| **pre-commit** | Runs `mix format --check-formatted` |
| **pre-push** | Runs `mix quality` (format, compile warnings, dialyzer, credo) |

### Conventional Commits

All commits must follow conventional commit format:

```
type(scope): description

# Examples:
feat: add new provider support
fix: resolve model lookup edge case
docs: update API documentation
chore: update dependencies
```

Types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`

## Docs & Guides

- [API and Support Policy](guides/api-and-support-policy.md) — Stable APIs, extension points, internal modules, and compatibility guarantees
- [Using the Data](guides/using-the-data.md) — Runtime API and querying
- [Consumer Integration](guides/consumer-integration.md) — Best practices for libraries using llm_db
- [Runtime Filters](guides/runtime-filters.md) — Load-time and runtime filtering
- [Sources & Engine](guides/sources-and-engine.md) — ETL pipeline, data sources, precedence
- [Schema System](guides/schema-system.md) — Zoi validation and data structures
- [Model Struct Evolution Proposal](guides/model-struct-evolution-proposal.md) — Proposed conditional pricing and richer capability metadata
- [Release Process](guides/release-process.md) — Snapshot-based releases

## License

Apache-2.0 - see LICENSE file for details.
