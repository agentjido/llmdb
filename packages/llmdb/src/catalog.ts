import {
  ModelNotFoundError,
  ProviderNotFoundError,
} from "./errors.js";
import { normalizeProviderId, parseModelSpec } from "./spec.js";
import type {
  FullCatalog,
  Manifest,
  Model,
  ModelSpec,
  ParsedModelSpec,
  ProviderCatalog,
  ProviderId,
} from "./types.js";

export function createCatalog(
  providers: readonly ProviderCatalog[],
  manifest: Manifest,
): FullCatalog {
  return new CompleteCatalog(providers, manifest);
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
