import assert from "node:assert/strict";
import test from "node:test";

import {
  createLLMDB,
  formatModelSpec,
  InvalidModelSpecError,
  llmdb,
  manifest,
  ModelNotFoundError,
  parseModelSpec,
  ProviderNotFoundError,
} from "@agentjido/llmdb";
import openai from "@agentjido/llmdb/providers/openai";

test("loads one provider through the default lazy API", async () => {
  const model = await llmdb.get("openai:gpt-5.4");

  assert.equal(model.id, "gpt-5.4");
  assert.equal(model.limits?.context, 1_050_000);
  assert.equal(llmdb.providerIds().length, manifest.provider_count);
});

test("caches loaded providers", async () => {
  const first = await llmdb.provider("openai");
  const second = await llmdb.provider("openai");

  assert.equal(first, second);
});

test("coalesces concurrent provider loads", async () => {
  let callCount = 0;
  const client = createLLMDB({
    loaders: {
      openai: async () => {
        callCount += 1;
        return openai;
      },
    },
  });

  const [first, second] = await Promise.all([
    client.provider("openai"),
    client.provider("openai"),
  ]);

  assert.equal(first, openai);
  assert.equal(second, openai);
  assert.equal(callCount, 1);
});

test("supports strict and optional lookups", async () => {
  assert.equal(await llmdb.find("missing:model"), undefined);
  assert.equal(await llmdb.find("openai:missing"), undefined);

  await assert.rejects(
    () => llmdb.get("missing:model"),
    ProviderNotFoundError,
  );
  await assert.rejects(
    () => llmdb.get("openai:missing"),
    ModelNotFoundError,
  );
});

test("resolves model aliases", async () => {
  assert.equal(
    (await llmdb.get("anthropic:claude-haiku-4.5")).id,
    "claude-haiku-4-5-20251001",
  );
});

test("preloads providers for synchronous provider access", async () => {
  await llmdb.preload(["openai", "anthropic"]);
  const anthropic = await llmdb.provider("anthropic");

  assert.equal(
    anthropic.get("claude-haiku-4.5").id,
    "claude-haiku-4-5-20251001",
  );
  assert.ok(anthropic.models().length > 10);
});

test("provides direct synchronous provider entrypoints", () => {
  assert.equal(openai.id, "openai");
  assert.equal(openai.get("gpt-5.4").name, "GPT-5.4");
  assert.equal(openai.find("missing"), undefined);
  assert.throws(() => openai.get("missing"), ModelNotFoundError);
});

test("does not read model or provider IDs from object prototypes", async () => {
  const client = createLLMDB({ loaders: {} });

  for (const reservedId of ["constructor", "toString", "__proto__"]) {
    assert.equal(openai.find(reservedId), undefined);
    assert.equal(openai.has(reservedId), false);
    assert.throws(() => openai.get(reservedId), ModelNotFoundError);
    assert.equal(await client.findProvider(reservedId), undefined);
    await assert.rejects(
      () => client.provider(reservedId),
      ProviderNotFoundError,
    );
  }
});

test("gives model aliases precedence over deprecated canonical stubs", async () => {
  const { default: xai } = await import("@agentjido/llmdb/providers/xai");

  assert.equal(xai.get("grok-code-fast-1").id, "grok-build-0.1");
  assert.equal(
    xai.get("grok-imagine-image-pro").id,
    "grok-imagine-image-quality",
  );
});

test("provides an explicit synchronous full catalog", async () => {
  const { catalog } = await import("@agentjido/llmdb/full");

  assert.equal(catalog.get("openai:gpt-5.4").id, "gpt-5.4");
  assert.equal(catalog.find("missing:model"), undefined);
  assert.ok(catalog.models().length > 1_000);
});

test("reconstructs the canonical snapshot on explicit import", async () => {
  const { snapshot } = await import("@agentjido/llmdb/snapshot");

  assert.equal(snapshot.snapshot_id, manifest.snapshot_id);
  assert.equal(
    Object.keys(snapshot.providers).length,
    manifest.provider_count,
  );
  assert.equal(snapshot.providers.openai?.models["gpt-5.4"]?.id, "gpt-5.4");
});

test("parses and formats both model spec forms", () => {
  assert.deepEqual(parseModelSpec("openai:gpt-5.4"), {
    providerId: "openai",
    modelId: "gpt-5.4",
  });
  assert.deepEqual(parseModelSpec("gpt-5.4@openai"), {
    providerId: "openai",
    modelId: "gpt-5.4",
  });
  assert.equal(
    formatModelSpec({ providerId: "openai", modelId: "gpt-5.4" }, "at"),
    "gpt-5.4@openai",
  );
  assert.throws(() => parseModelSpec("gpt-5.4"), InvalidModelSpecError);
  assert.throws(() => parseModelSpec("model@open:ai"), InvalidModelSpecError);
});

test("uses known providers to resolve specs with both separators", () => {
  assert.deepEqual(
    parseModelSpec("google_vertex:claude-haiku-4-5@20251001"),
    {
      providerId: "google_vertex",
      modelId: "claude-haiku-4-5@20251001",
    },
  );
  assert.deepEqual(parseModelSpec("model:version@google_vertex"), {
    providerId: "google_vertex",
    modelId: "model:version",
  });
});

test("round-trips every canonical provider:model spec", async () => {
  const { snapshot } = await import("@agentjido/llmdb/snapshot");
  let modelCount = 0;

  for (const [providerId, provider] of Object.entries(snapshot.providers)) {
    for (const modelId of Object.keys(provider.models)) {
      const parsed = { providerId, modelId };

      assert.deepEqual(parseModelSpec(formatModelSpec(parsed)), parsed);
      modelCount += 1;
    }
  }

  assert.equal(modelCount, manifest.model_count);
});

test("keeps colons inside model IDs", () => {
  assert.deepEqual(
    parseModelSpec(
      "amazon_bedrock:anthropic.claude-3-haiku-20240307-v1:0",
    ),
    {
      providerId: "amazon_bedrock",
      modelId: "anthropic.claude-3-haiku-20240307-v1:0",
    },
  );
});
