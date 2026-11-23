import assert from "node:assert/strict";
import { test } from "node:test";

import { fetchModel } from "@agentjido/llmdb/online";
import { createCatalogFromSnapshot } from "@agentjido/llmdb";
import snapshot from "@agentjido/llmdb/snapshot";

const id = "openai/gpt-3.5-turbo-0613";
const provider = "openrouter";
const spec = { modelId: id, providerId: provider };

function response(model) {
  return Response.json({ schema_version: 1, snapshot_id: snapshot.snapshot_id, model });
}

test("fetches only exact display metadata", async () => {
  const model = await fetchModel(spec, {
    fetch(url, options) {
      assert.equal(url, `https://llmcatalog.dev/api/v1/models/${provider}/${id}`);
      assert.equal(options.redirect, "error");
      return response({ id, provider, retired: true, base_url: "https://example.invalid" });
    },
  });
  assert.deepEqual(model, { id, provider, retired: true });
});

test("rejects mismatched IDs and large responses", async () => {
  await assert.rejects(fetchModel(spec, {
    fetch: async () => response({ id: "different", provider }),
  }), /Invalid model metadata/);

  await assert.rejects(fetchModel(spec, {
    fetch: async () => new Response("x".repeat(65_537)),
  }), /byte limit/);
});

test("preserves structured model IDs for providers outside the installed catalog", async () => {
  const model = await fetchModel({ providerId: "future_provider", modelId: "example:version" }, {
    fetch(url) {
      assert.equal(url, "https://llmcatalog.dev/api/v1/models/future_provider/example%3Aversion");
      return response({ id: "example:version", provider: "future_provider" });
    },
  });
  assert.equal(model.id, "example:version");
});

test("accepts an offer with input modalities and no output modalities", async () => {
  const id = "bge-reranker-v2-m3";
  const provider = "albert";
  const modalities = { input: ["text"] };
  const model = await fetchModel({ modelId: id, providerId: provider }, {
    fetch: async () => response({ id, provider, modalities }),
  });
  assert.deepEqual(model.modalities, modalities);
});

test("rejects malformed known metadata fields", async () => {
  for (const fields of [
    { retired: "false" },
    { pricing: "not-pricing" },
    { cost: { input: "free" } },
    { modalities: { input: "text" } },
  ]) {
    await assert.rejects(fetchModel(spec, {
      fetch: async () => response({ id, provider, ...fields }),
    }), /Invalid model metadata field/);
  }
});

test("loads a full disk-format snapshot into the offline catalog", () => {
  const catalog = createCatalogFromSnapshot(snapshot);
  assert.equal(catalog.manifest.snapshot_id, snapshot.snapshot_id);
  assert.deepEqual(catalog.get(spec), snapshot.providers[provider].models[id]);
});
