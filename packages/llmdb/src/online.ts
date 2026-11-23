/// <reference lib="dom" preserve="true" />

import { formatModelSpec, parseModelSpec } from "./spec.js";
import type { JsonValue, ModelSpec } from "./types.js";

const origin = "https://llmcatalog.dev/api/v1/models";
const maxBytes = 65_536;
const displayFields = [
  "name", "release_date", "last_updated", "knowledge", "limits", "cost",
  "pricing", "modalities", "capabilities", "tags", "deprecated", "retired",
  "lifecycle", "catalog_only", "aliases",
] as const;

export interface ModelMetadata {
  readonly id: string;
  readonly provider: string;
  readonly [field: string]: JsonValue | undefined;
}

export interface FetchModelOptions {
  readonly timeoutMs?: number;
  readonly fetch?: typeof globalThis.fetch;
}

/** Fetches display metadata for an exact provider-model ID. */
export async function fetchModel(
  spec: ModelSpec,
  options: FetchModelOptions = {},
): Promise<ModelMetadata> {
  const { providerId, modelId } = parseModelSpec(
    typeof spec === "string" ? spec : formatModelSpec(spec, "at"),
  );
  const pieces = modelId.split("/");
  const timeout = options.timeoutMs ?? 5_000;

  if (new TextEncoder().encode(modelId).length > 512 ||
      pieces.some(piece => piece === "" || piece === "." || piece === "..")) {
    throw new RangeError("Invalid model ID");
  }

  if (!Number.isInteger(timeout) || timeout < 1 || timeout > 30_000) {
    throw new RangeError("Invalid request timeout");
  }

  const response = await (options.fetch ?? globalThis.fetch)(
    `${origin}/${encodeURIComponent(providerId)}/${pieces.map(encodeURIComponent).join("/")}`,
    { headers: { accept: "application/json" }, redirect: "error", signal: AbortSignal.timeout(timeout) },
  );

  if (response.status !== 200) {
    await response.body?.cancel();
    throw new Error(`LLMCatalog returned HTTP ${response.status}`);
  }

  const payload: unknown = JSON.parse(await readBounded(response));
  if (!isObject(payload) || payload.schema_version !== 1 ||
      typeof payload.snapshot_id !== "string" || !/^[0-9a-f]{64}$/.test(payload.snapshot_id) ||
      !isObject(payload.model) || payload.model.id !== modelId || payload.model.provider !== providerId) {
    throw new Error("Invalid model metadata");
  }

  const result: Record<string, JsonValue> = { id: modelId, provider: providerId };
  for (const field of displayFields) {
    if (Object.hasOwn(payload.model, field)) result[field] = payload.model[field] as JsonValue;
  }
  return result as ModelMetadata;
}

async function readBounded(response: Response): Promise<string> {
  const reader = response.body?.getReader();
  if (!reader) throw new Error("Empty metadata response");

  const decoder = new TextDecoder("utf-8", { fatal: true });
  let bytes = 0;
  let body = "";
  try {
    for (;;) {
      const chunk = await reader.read();
      if (chunk.done) return body + decoder.decode();
      bytes += chunk.value.byteLength;
      if (bytes > maxBytes) {
        await reader.cancel();
        throw new Error("Metadata response exceeds the byte limit");
      }
      body += decoder.decode(chunk.value, { stream: true });
    }
  } finally {
    reader.releaseLock();
  }
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
