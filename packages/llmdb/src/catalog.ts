import {
  ModelNotFoundError,
  ProviderNotFoundError,
} from "./errors.js";
import { createProviderCatalog } from "./provider.js";
import { normalizeProviderId, parseModelSpec } from "./spec.js";
import type {
  FullCatalog,
  Manifest,
  Model,
  ModelSpec,
  ParsedModelSpec,
  ProviderCatalog,
  ProviderId,
  Snapshot,
} from "./types.js";

export function createCatalog(
  providers: readonly ProviderCatalog[],
  manifest: Manifest,
): FullCatalog {
  return new CompleteCatalog(providers, manifest);
}

/** Creates an offline catalog from a verified release snapshot. */
export function createCatalogFromSnapshot(snapshot: Snapshot): FullCatalog {
  if (snapshot.schema_version !== 1 || snapshot.version !== 2 ||
      !/^[0-9a-f]{64}$/.test(snapshot.snapshot_id) || !snapshot.providers) {
    throw new Error("Unsupported full catalog snapshot");
  }

  const providers = Object.values(snapshot.providers).map(provider => createProviderCatalog(provider));
  const manifest: Manifest = {
    format_version: 1,
    snapshot_schema_version: 1,
    catalog_version: snapshot.version,
    generated_at: snapshot.generated_at,
    snapshot_id: snapshot.snapshot_id,
    provider_count: providers.length,
    model_count: providers.reduce((count, provider) => count + provider.modelIds.length, 0),
    providers: Object.fromEntries(providers.map(provider => [
      provider.id,
      {
        id: provider.id,
        name: provider.data.name ?? null,
        base_url: provider.data.base_url ?? null,
        doc: provider.data.doc ?? null,
        alias_of: provider.data.alias_of ?? null,
        catalog_only: provider.data.catalog_only ?? false,
        model_count: provider.modelIds.length,
      },
    ])),
  };

  return createCatalog(providers, manifest);
}

class CompleteCatalog implements FullCatalog {
  readonly manifest: Manifest;
  readonly #providers: ReadonlyMap<ProviderId, ProviderCatalog>;

  constructor(providers: readonly ProviderCatalog[], manifest: Manifest) {
    this.manifest = manifest;
    this.#providers = new Map(
      providers.map((provider) => [provider.id, provider]),
    );
  }

  providerIds(): readonly ProviderId[] {
    return Object.keys(this.manifest.providers);
  }

  provider(providerId: ProviderId): ProviderCatalog {
    const provider = this.findProvider(providerId);

    if (provider === undefined) {
      throw new ProviderNotFoundError(providerId);
    }

    return provider;
  }

  findProvider(providerId: ProviderId): ProviderCatalog | undefined {
    return this.#providers.get(normalizeProviderId(providerId));
  }

  get(spec: ModelSpec): Model {
    const parsed = normalizeSpec(spec);
    const provider = this.provider(parsed.providerId);
    const model = provider.find(parsed.modelId);

    if (model === undefined) {
      throw new ModelNotFoundError(parsed.providerId, parsed.modelId);
    }

    return model;
  }

  find(spec: ModelSpec): Model | undefined {
    const parsed = normalizeSpec(spec);
    return this.findProvider(parsed.providerId)?.find(parsed.modelId);
  }

  models(providerId?: ProviderId): readonly Model[] {
    if (providerId !== undefined) {
      return this.findProvider(providerId)?.models() ?? [];
    }

    return [...this.#providers.values()].flatMap((provider) =>
      provider.models(),
    );
  }
}

function normalizeSpec(spec: ModelSpec): ParsedModelSpec {
  return typeof spec === "string"
    ? parseModelSpec(spec)
    : {
        providerId: normalizeProviderId(spec.providerId),
        modelId: spec.modelId,
      };
}
