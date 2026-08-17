# Release Process

## Snapshot-Based Model Data

LLM Models packages a pre-built snapshot at `priv/llm_db/snapshot.json`.

### Snapshot Structure

V2 schema uses nested providers with embedded models:

```json
{
  "version": 2,
  "generated_at": "2025-11-06T14:23:45.123456Z",
  "providers": {
    "openai": {
      "id": "openai",
      "name": "OpenAI",
      "base_url": "https://api.openai.com/v1",
      "models": {
        "gpt-4": {
          "id": "gpt-4",
          "provider": "openai",
          "name": "GPT-4",
          "capabilities": {...},
          "limits": {...},
          "cost": {...}
        }
      }
    }
  }
}
```

### Runtime Loading

```elixir
# Reads from priv/llm_db/snapshot.json
{:ok, _} = LLMDB.load()
```

Compile-time embed (zero runtime IO):

```elixir
# config/config.exs
config :llm_db, compile_embed: true
```

Snapshot is inlined into BEAM bytecode during compilation. Requires recompilation on snapshot changes.

## Updating Model Data

### 1. Pull Remote Sources

```bash
$ mix llm_db.pull
Pulling from configured sources...
✓ ModelsDev: 450 models cached at priv/llm_db/cache/models_dev.json
```

### 2. Build Snapshot

```bash
$ mix llm_db.build
$ mix llm_db.build --install
```

**Outputs**:

1. `_build/llm_db/snapshot/snapshot.json` - Canonical snapshot artifact
2. `_build/llm_db/snapshot/snapshot-meta.json` - Snapshot metadata
3. `priv/llm_db/snapshot.json` - Installed packaged snapshot when `--install` is used

### 3. Publish Snapshot Catalog Assets

```bash
$ mix llm_db.snapshot.publish
$ mix llm_db.history.rebuild --publish
```

This publishes immutable snapshot releases plus the mutable `catalog-index`
assets: `latest.json`, `snapshot-index.json`, `history.tar.gz`, and `history-meta.json`.

## Versioning and Tagging

Date-based versioning: `YYYY.M.D`

### Update Version

```bash
$ mix llm_db.version
Updated version to 2025.11.6 in mix.exs
```

Updates `@version` in `mix.exs`.

### Generate Changelog and Tag

```bash
$ mix git_ops.release
Analyzing commits since last release...
Updating CHANGELOG.md...
Creating git tag 2025.11.6...
```

1. Parses conventional commits since last tag
2. Updates `CHANGELOG.md`
3. Creates git tag `2025.11.6`

### Publish with CI

```bash
$ gh workflow run release.yml --ref main \
    -f dry_run=false \
    -f skip_tests=false
```

The preparation run validates the source, creates the release commit and tag,
and pushes both. It then dispatches a second run from the release commit. The
second run publishes Hex.pm first, publishes NPM with trusted publishing, and
creates the GitHub release.

## Snapshot Format

### V2 Schema

```json
{
  "version": 2,
  "generated_at": "ISO8601 timestamp",
  "providers": {
    "provider_atom_as_string": {
      "id": "provider_atom_as_string",
      "name": "Provider Name",
      "base_url": "https://...",
      "env": {...},
      "doc": "https://...",
      "extra": {...},
      "models": {
        "model_id": {
          "id": "model_id",
          "provider": "provider_atom_as_string",
          "name": "Model Name",
          "capabilities": {...},
          "limits": {...},
          "cost": {...},
          "modalities": {...},
          "deprecated": false,
          "aliases": [...],
          "extra": {...}
        }
      }
    }
  }
}
```

**Runtime-only indexes** (rebuilt during `LLMDB.load/1`):
- `providers_by_id`
- `models_by_key`
- `models_by_provider`
- `aliases_by_key`

## Release Triggers

1. Upstream data changes (new models, pricing, capabilities)
2. Schema changes (new fields, modality types)
3. Provider additions
4. Taxonomy updates
5. Metadata corrections

## Release Checklist

- [ ] `mix llm_db.pull`
- [ ] `mix llm_db.build`
- [ ] `mix test`
- [ ] Verify `mix llm_db.build --check --install`
- [ ] Commit snapshot and generated files
- [ ] `mix llm_db.version`
- [ ] `mix git_ops.release`
- [ ] Review `CHANGELOG.md`
- [ ] `git push && git push --tags`

## Local Release Preparation

```bash
$ mix llm_db.pull && \
  mix llm_db.build && \
  mix test && \
  mix llm_db.version && \
  mix git_ops.release && \
  git push && \
  git push --tags
```

Or via mix alias:

```elixir
defp aliases do
  [
    release: [
      "llm_db.pull",
      "llm_db.build",
      "test",
      "llm_db.version",
      "git_ops.release"
    ]
  ]
end
```

```bash
$ mix release
$ git push && git push --tags
```

Use the CI workflow for normal registry releases. The local commands are for
maintainer diagnosis and emergency recovery.

## Snapshot Versions

- **v1**: Flat lists (deprecated)
- **v2**: Nested providers with models (current)

## Snapshot Size

Current: ~1.2 MB (400 models × 12 providers)

**Optimization options**:
1. Filter deprecated models at build time
2. gzip compression (transparent in BEAM)
3. Split by provider (on-demand load)
4. Remove `:extra` fields

## Schema Evolution Signals

- New capability types (e.g., "video generation")
- New cost models (e.g., "per-character")
- New modality types (e.g., "3d", "code")
- Provider-specific features becoming common

**Schema changes require updates to**:
1. Source adapters (ModelsDev transform)
2. Validation schemas (Zoi definitions)
3. Documentation (capability lists)

## Related Guides

- [Schema System](schema-system.md)
- [Sources and Engine](sources-and-engine.md)
- [Using the Data](using-the-data.md)
