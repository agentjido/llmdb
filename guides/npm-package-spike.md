# NPM Package Spike

The repository contains a private NPM workspace and one publishable package:
`@jido/llmdb`.

This is a spike. It tests an offline-first provider-sharded package, a typed
developer API, package size, and one-way synchronization with the Elixir
catalog. It does not publish to NPM.

## Ownership boundary

Elixir remains the only metadata production system. It pulls sources, runs the
ETL pipeline, validates data, and writes `priv/llm_db/snapshot.json`.

The `mix llm_db.npm.export` task:

1. reads and verifies the canonical snapshot with strict integrity;
2. writes one exact wire-data shard for each provider;
3. writes a small provider manifest;
4. reconstructs the source snapshot from the shards; and
5. verifies the reconstructed snapshot with the existing Elixir code.

Node.js generates only package entrypoints, loader tables, and declarations
from those Elixir-owned files. It does not define or transform metadata.

Provider IDs used as NPM subpaths can contain lowercase letters, digits,
underscores, and hyphens. The exporter rejects other snapshot-valid characters,
such as colons, because they are not safe in file names on all supported
platforms.

## Package entrypoints

| Entrypoint | Purpose |
| --- | --- |
| `@jido/llmdb` | Small lazy-loading API and manifest |
| `@jido/llmdb/providers/openai` | One synchronous provider catalog |
| `@jido/llmdb/full` | Complete synchronous query catalog |
| `@jido/llmdb/snapshot` | Reconstructed canonical wire snapshot |
| `@jido/llmdb/raw` | Alias for the snapshot entrypoint |

The default API performs no network requests. It dynamically imports one
provider module and caches its promise. Concurrent requests for one provider
share the same load.

## Workspace commands

Run these commands from the repository root:

```bash
npm ci
npm run npm:sync:check
npm run npm:typecheck
npm run npm:test
npm run npm:pack
npm run npm:check
```

Export shards without building TypeScript:

```bash
mix llm_db.npm.export
```

After `mix llm_db.version` changes the Elixir package version, update the
downstream NPM package and lock file:

```bash
npm run npm:sync
```

## Release follow-up

If the spike is accepted:

1. reserve the `@jido/llmdb` package;
2. configure NPM Trusted Publishing for a dedicated GitHub workflow;
3. publish Hex and NPM from the same release commit and CalVer;
4. run the Elixir snapshot and shard checks before NPM packaging; and
5. add an explicit release dry run before the first stable version.

Do not publish from the daily metadata workflow until there is a version policy
for multiple snapshot changes in one CalVer period.
