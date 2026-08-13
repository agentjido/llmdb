import { InvalidModelSpecError } from "./errors.js";
import { manifest } from "./generated/manifest.js";
import type { ParsedModelSpec, ProviderId } from "./types.js";

const PROVIDER_PATTERN = /^[a-z0-9][a-z0-9_.-]{0,63}$/;
const KNOWN_PROVIDER_IDS = new Set(Object.keys(manifest.providers));

export function parseModelSpec(spec: string): ParsedModelSpec {
  const input = spec.trim();

  if (input.length === 0) {
    throw new InvalidModelSpecError(spec, "the value is empty");
  }

  const atIndex = input.lastIndexOf("@");
  if (atIndex > 0 && atIndex < input.length - 1) {
    const providerCandidate = input.slice(atIndex + 1).trim();
    const providerId = normalizeProviderId(providerCandidate);

    if (
      PROVIDER_PATTERN.test(providerId) &&
      (!input.includes(":") || KNOWN_PROVIDER_IDS.has(providerId))
    ) {
      return parseSegments(spec, providerCandidate, input.slice(0, atIndex));
    }
  }

  const colonIndex = input.indexOf(":");
  if (colonIndex > 0 && colonIndex < input.length - 1) {
    return parseSegments(
      spec,
      input.slice(0, colonIndex),
      input.slice(colonIndex + 1),
    );
  }

  throw new InvalidModelSpecError(
    spec,
    'expected "provider:model" or "model@provider"',
  );
}

export function formatModelSpec(
  spec: ParsedModelSpec,
  format: "colon" | "at" = "colon",
): string {
  return format === "at"
    ? `${spec.modelId}@${spec.providerId}`
    : `${spec.providerId}:${spec.modelId}`;
}

export function normalizeProviderId(providerId: ProviderId): ProviderId {
  const trimmed = providerId.trim();

  return KNOWN_PROVIDER_IDS.has(trimmed)
    ? trimmed
    : trimmed.replaceAll("-", "_").replaceAll(".", "_");
}

function parseSegments(
  originalSpec: string,
  providerSegment: string,
  modelSegment: string,
): ParsedModelSpec {
  const providerId = normalizeProviderId(providerSegment);
  const modelId = modelSegment.trim();

  if (!PROVIDER_PATTERN.test(providerId)) {
    throw new InvalidModelSpecError(originalSpec, "the provider ID is invalid");
  }

  if (modelId.length === 0) {
    throw new InvalidModelSpecError(originalSpec, "the model ID is empty");
  }

  return { providerId, modelId };
}
