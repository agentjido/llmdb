# @agentjido/llmdb

Offline-first, typed access to the LLM DB model metadata catalog.

The default API loads one generated provider shard at a time. It performs no
network requests. Provider modules are cached after their first use.

This package is an NPM spike. The Elixir pipeline in
[agentjido/llmdb](https://github.com/agentjido/llmdb) owns all metadata,
validation, and snapshot integrity.

## Install

```bash
npm install @agentjido/llmdb
```

The package is ESM-only and requires Node.js 22.14 or newer.

## Lazy API

Use the default API for most applications:

```ts
import { llmdb } from "@agentjido/llmdb";

const model = await llmdb.get("openai:gpt-5.4");

model.limits?.context;
model.cost?.input;
```

`get` returns a model or throws a typed error. `find` returns `undefined`:

```ts
const model = await llmdb.find("openai:gpt-5.4");
```

Load one provider and use it synchronously:

```ts
const openai = await llmdb.provider("openai");

openai.get("gpt-5.4");
openai.find("gpt-5.4");
openai.models();
```

Preload providers before a request path:

```ts
await llmdb.preload(["openai", "anthropic"]);
```

## Direct provider import

Direct provider imports give bundlers an explicit boundary and provide model-ID
autocomplete:

```ts
import openai from "@agentjido/llmdb/providers/openai";

const model = openai.get("gpt-5.4");
```

## Full catalog

Import the complete synchronous catalog only when you need it:

```ts
import { catalog } from "@agentjido/llmdb/full";

const model = catalog.get("openai:gpt-5.4");
```

The canonical wire snapshot is also available through an explicit entrypoint:

```ts
import snapshot from "@agentjido/llmdb/snapshot";
```

`@agentjido/llmdb/raw` is an alias for the same snapshot entrypoint.

## Errors

The package exports:

- `InvalidModelSpecError`
- `ProviderNotFoundError`
- `ModelNotFoundError`

## Data ownership

The data flow is one way:

```text
Elixir sources and ETL
        |
        v
priv/llm_db/snapshot.json
        |
        v
mix llm_db.npm.export
        |
        v
generated provider shards
        |
        v
NPM entrypoints
```

Generated shards, TypeScript loader tables, and `dist` files are not committed.
The export task reconstructs the canonical snapshot from its shards and runs
the existing Elixir integrity check.

The built provider entrypoints use a compact format with shared key and value
dictionaries. They expand to the same public provider and model objects when
imported. Direct provider,
lazy, full-catalog, and raw snapshot imports keep the same API. The package
check reports the largest provider entrypoints and limits the unpacked package
to 7 MB.

Run `npm run size:report --workspace @agentjido/llmdb` to measure every
provider, model field, repeated object key, null literal, and large metadata
group. For the snapshot in release 2026.8.3, the source provider JSON is
7,691,333 bytes. Object keys use 4,395,004 bytes, with 4,329,856 bytes from
repeated keys. The 58,774 null literals use 235,096 bytes. Model `extra` fields
use about 2.40 MB, including about 445 KB of `llmfit` data and 140 KB of
benchmark data.

The shared dictionaries reduce the built package to about 4.48 MB unpacked.
This keeps all current imports and public data. A future major size reduction
can put `extra`, `llmfit`, and benchmark data in an explicit rich-data export.
A package split is useful only if that data grows again. Compressed runtime
assets are not used because direct synchronous provider imports and common
bundlers must continue to work without file-system or decompression behavior.

The NPM version is downstream from the `@version` value in `mix.exs`. Run
`npm run npm:sync` at the repository root after the Elixir version changes.
