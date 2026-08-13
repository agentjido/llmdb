# @jido/llmdb

Offline-first, typed access to the LLM DB model metadata catalog.

The default API loads one generated provider shard at a time. It performs no
network requests. Provider modules are cached after their first use.

This package is an NPM spike. The Elixir pipeline in
[agentjido/llmdb](https://github.com/agentjido/llmdb) owns all metadata,
validation, and snapshot integrity.

## Install

```bash
npm install @jido/llmdb
```

The package is ESM-only and requires Node.js 22.14 or newer.

## Lazy API

Use the default API for most applications:

```ts
import { llmdb } from "@jido/llmdb";

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
import openai from "@jido/llmdb/providers/openai";

const model = openai.get("gpt-5.4");
```

## Full catalog

Import the complete synchronous catalog only when you need it:

```ts
import { catalog } from "@jido/llmdb/full";

const model = catalog.get("openai:gpt-5.4");
```

The canonical wire snapshot is also available through an explicit entrypoint:

```ts
import snapshot from "@jido/llmdb/snapshot";
```

`@jido/llmdb/raw` is an alias for the same snapshot entrypoint.

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

The NPM version is downstream from the `@version` value in `mix.exs`. Run
`npm run npm:sync` at the repository root after the Elixir version changes.
