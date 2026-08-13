import {
  ModelNotFoundError,
  ProviderNotFoundError,
} from "./errors.js";
import {
  manifest as defaultManifest,
  type KnownProviderId,
} from "./generated/manifest.js";
import { providerLoaders } from "./generated/provider-loaders.js";
import { normalizeProviderId, parseModelSpec } from "./spec.js";
import type {
  LLMDBClient,
  Manifest,
  Model,
  ModelSpec,
  ParsedModelSpec,
  ProviderCatalog,
  ProviderId,
  ProviderLoader,
} from "./types.js";

export interface CreateLLMDBOptions {
  readonly manifest?: Manifest;
  readonly loaders?: Readonly<Record<string, ProviderLoader>>;
}

export function createLLMDB(): LLMDBClient<KnownProviderId>;
export function createLLMDB(options: CreateLLMDBOptions): LLMDBClient;
export function createLLMDB(
  options: CreateLLMDBOptions = {},
): LLMDBClient {
  return new LazyCatalog(
    options.manifest ?? defaultManifest,
    options.loaders ?? providerLoaders,
  );
}

export type { KnownProviderId };

class LazyCatalog implements LLMDBClient {
  readonly manifest: Manifest;
  readonly #loaders: Readonly<Record<string, ProviderLoader>>;
  readonly #cache = new Map<ProviderId, Promise<ProviderCatalog>>();

  constructor(
    manifest: Manifest,
    loaders: Readonly<Record<string, ProviderLoader>>,
  ) {
    this.manifest = manifest;
    this.#loaders = loaders;
  }

  providerIds(): readonly ProviderId[] {
    return Object.keys(this.manifest.providers);
  }

  async provider(providerId: ProviderId): Promise<ProviderCatalog> {
    const provider = await this.findProvider(providerId);

    if (provider === undefined) {
      throw new ProviderNotFoundError(providerId);
    }

    return provider;
  }

  findProvider(
    providerId: ProviderId,
  ): Promise<ProviderCatalog | undefined> {
    const normalizedId = normalizeProviderId(providerId);
    const loader = Object.hasOwn(this.#loaders, normalizedId)
      ? this.#loaders[normalizedId]
      : undefined;

    if (loader === undefined) {
      return Promise.resolve(undefined);
    }

    const cached = this.#cache.get(normalizedId);
    if (cached !== undefined) {
      return cached;
    }

    const pending = loader().catch((error: unknown) => {
      this.#cache.delete(normalizedId);
      throw error;
    });

    this.#cache.set(normalizedId, pending);
    return pending;
  }

  async get(spec: ModelSpec): Promise<Model> {
    const parsed = normalizeSpec(spec);
    const provider = await this.provider(parsed.providerId);
    const model = provider.find(parsed.modelId);

    if (model === undefined) {
      throw new ModelNotFoundError(parsed.providerId, parsed.modelId);
    }

    return model;
  }

  async find(spec: ModelSpec): Promise<Model | undefined> {
    const parsed = normalizeSpec(spec);
    const provider = await this.findProvider(parsed.providerId);
    return provider?.find(parsed.modelId);
  }

  async models(providerId: ProviderId): Promise<readonly Model[]> {
    return (await this.provider(providerId)).models();
  }

  async preload(providerIds: readonly ProviderId[]): Promise<void> {
    await Promise.all(providerIds.map((providerId) => this.provider(providerId)));
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
