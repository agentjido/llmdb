# Runtime and Maintainer Boundaries

LLM DB is a read-mostly runtime catalog. Building, refreshing, publishing, and
reconstructing that catalog are repository-maintainer workflows. This guide is
the inventory and compatibility plan for keeping those two concerns separate.

## Supported runtime surface

These modules are covered by the runtime compatibility policy:

| Modules | Ownership |
| --- | --- |
| `LLMDB`, `LLMDB.Model`, `LLMDB.Provider`, `LLMDB.Spec` | Typed catalog queries and model-spec handling |
| `LLMDB.History` | Read-only access to installed history artifacts |
| `LLMDB.LoadError` | First-use catalog initialization failure |
| `LLMDB.Snapshot` | Versioned snapshot artifact reading and writing |
| `LLMDB.Source` | Supported build-time source extension behaviour |

Runtime implementation modules are internal even though they remain shipped:

| Modules | Ownership |
| --- | --- |
| LLMDB.Catalog, LLMDB.Loader, LLMDB.Packaged, LLMDB.Query, LLMDB.Runtime | Lazy loading, indexing, storage, and query execution |
| LLMDB.Config, LLMDB.ExecutionContract, LLMDB.Merge, LLMDB.Normalize, LLMDB.Pricing, LLMDB.Schema.Pricing | Shared runtime normalization, filtering, execution inference, and pricing support |
| LLMDB.Generated.ProviderRegistry, LLMDB.Generated.ValidModalities | Generated bounded decode registries |
| LLMDB.Snapshot.ReleaseStore, LLMDB.Snapshot.Sparse | Shared remote snapshot/history transport and schema-v2 sparse wire codec used by configured runtime readers and maintainer tasks |

The internal module layout and raw map/index shapes are not compatibility
contracts. Consumers should enter through `LLMDB`, `LLMDB.History`, or the
versioned `LLMDB.Snapshot` format.

## Supported tooling entry points

The supported command surface is the Mix task name, not the implementation
module it currently calls:

| Task | Ownership |
| --- | --- |
| `mix llm_db.models` | Read-only catalog inspection |
| `mix llm_db.install` | Optional Igniter-based consumer installation |
| `mix llm_db.snapshot.fetch` | Fetch/install a published snapshot |
| `mix llm_db.pull` | Maintainer-only upstream synchronization and the sole automatic dotenv boundary |
| `mix llm_db.build`, `mix llm_db.snapshot.build` | Maintainer-only canonical snapshot build (`snapshot.build` is a supported alias) |
| `mix llm_db.snapshot.publish` | Maintainer-only snapshot publication |
| `mix llm_db.history.backfill` | Deprecated legacy Git-history backfill kept callable through the compatibility window |
| `mix llm_db.history.migrate_git` | One-time migration to snapshot-store history |
| `mix llm_db.history.rebuild`, `mix llm_db.history.sync`, `mix llm_db.history.check` | Published history maintenance |
| `mix llm_db.version` | Maintainer-only CalVer bump |

The corresponding task modules are `Mix.Tasks.LlmDb.Build`,
`Mix.Tasks.LlmDb.History.Backfill`, `Mix.Tasks.LlmDb.History.Check`,
`Mix.Tasks.LlmDb.History.MigrateGit`, `Mix.Tasks.LlmDb.History.Rebuild`,
`Mix.Tasks.LlmDb.History.Sync`, `Mix.Tasks.LlmDb.Install`,
`Mix.Tasks.LlmDb.Models`, `Mix.Tasks.LlmDb.Pull`,
`Mix.Tasks.LlmDb.Snapshot.Build`, `Mix.Tasks.LlmDb.Snapshot.Fetch`,
`Mix.Tasks.LlmDb.Snapshot.Publish`, and `Mix.Tasks.LlmDb.Version`.
Mix.Tasks.LlmDb.Install.Docs is an internal helper for the conditional install
task.

The experimental NPM spike uses `LLMDB.NPM.Exporter` through
`Mix.Tasks.LlmDb.Npm.Export`. These repository-only tools generate provider
shards for `@agentjido/llmdb`. They are not part of the supported runtime or Mix task
compatibility surface.

## Compatibility facades and direct tooling internals

No module or task is removed in this minor release.

| Current direct call | Supported replacement | Status |
| --- | --- | --- |
| `LLMDB.Application` direct callback | Rely on lazy queries; use `LLMDB.load/1` for explicit loading | Compiler-deprecated for one minor release |
| `LLMDB.Dotenv.load!/1` | `mix llm_db.pull` | Compiler-deprecated; pull remains task-scoped |
| `LLMDB.Store` query calls | Equivalent `LLMDB` query/load calls | Compatibility facade; direct use is documentation-deprecated |
| `LLMDB.Engine.run/1`, `LLMDB.Snapshot.Builder` | `mix llm_db.build` | Documentation-deprecated maintainer orchestration |
| `LLMDB.History.Backfill` | One-time `mix llm_db.history.migrate_git --publish`, then `mix llm_db.history.rebuild --publish` | Compiler- and runtime-deprecated; remains callable until no earlier than `v2027.0.0` |
| `LLMDB.History.Migrator`, `LLMDB.History.Rebuilder`, `LLMDB.History.Bundle`, `LLMDB.History.Diff`, `LLMDB.History.Lineage` | Corresponding `mix llm_db.history.*` task | Documentation-deprecated maintainer orchestration with internal shared diff/lineage logic |
| `LLMDB.Snapshot.ReleaseStore` mutation/publishing calls | `mix llm_db.snapshot.publish` or `mix llm_db.history.rebuild --publish` | Internal shared transport; runtime fetch behavior remains supported through configuration |
| `LLMDB.Enrich`, `LLMDB.Validate`, `LLMDB.Enrich.AzureWireProtocol`, `LLMDB.Enrich.RuntimeContract` | `mix llm_db.build` | Internal ETL stages |
| LLMDB.Sources.Anthropic, LLMDB.Sources.Google, LLMDB.Sources.Llmfit, LLMDB.Sources.Local, LLMDB.Sources.ModelsDev, LLMDB.Sources.OpenAI, LLMDB.Sources.OpenRouter, LLMDB.Sources.Remote, LLMDB.Sources.XAI, LLMDB.Sources.Zenmux | `LLMDB.Source` for extensions; `mix llm_db.pull`/`build` for workflows | Internal bundled adapters and shared remote transport |

Documentation-only deprecation avoids warnings inside the still-supported task
wrappers during the extraction window. It does not grant these modules a new
public compatibility guarantee.

## Dependency ownership

Every direct dependency remains available in this minor release:

| Dependency | Current owner and plan |
| --- | --- |
| `zoi` | Runtime schemas and validation; remains required |
| `jason` | Runtime snapshot decoding plus tooling serialization; remains required |
| `req` | Remote release snapshot/history reads and maintainer source transport; remains required until remote transport is extracted or replaced |
| `toml` | Maintainer source ingestion; candidate for a companion tooling package, but remains required while tasks ship here |
| `dotenvy` | Deprecated `LLMDB.Dotenv` facade and `mix llm_db.pull`; remains required through the compatibility window |
| `igniter` | Optional install-task integration; remains optional |
| `plug`, `meck` | Test-only dependencies |
| `ex_doc`, `git_ops`, `git_hooks`, `usage_rules` | Development/release tooling with `runtime: false` where applicable |
| `dialyxir`, `credo` | Development/test quality tooling with `runtime: false` |

## Extraction and removal sequence

1. This minor release documents the boundary, keeps every task/module working,
   and deprecates direct compatibility calls with concrete replacements.
2. A later compatible release may introduce a companion package and have the
   existing Mix tasks delegate to it. Task names and options remain stable
   during that transition.
3. After at least one minor deprecation window, the next major release may
   remove maintainer implementation modules and compatibility facades from the
   core package.
4. `LLMDB.Dotenv` and core `dotenvy` can be removed only in that major release,
   after `mix llm_db.pull` owns an equivalent task-private or companion
   implementation.
5. `toml` can move with source ingestion. `req` can leave the runtime dependency
   graph only after configured GitHub-release snapshot/history reads are moved
   behind an equivalent adapter or companion dependency.

The legacy `mix llm_db.history.backfill` task and `LLMDB.History.Backfill`
functions may be removed no earlier than `v2027.0.0`, and only after at least
one minor release has carried their actionable deprecation warnings. The
maintained replacement is the one-time `mix llm_db.history.migrate_git --publish`
seed followed by `mix llm_db.snapshot.publish` and
`mix llm_db.history.rebuild --publish` for new observations.

Upstream synchronization never runs during application startup, lazy catalog
initialization, explicit `LLMDB.load/1`, or queries. Provider credentials and
dotenv parsing remain exclusively inside the maintainer pull workflow.
