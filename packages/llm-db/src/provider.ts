import { ModelNotFoundError } from "./errors.js";
import type {
  Model,
  Provider,
  ProviderCatalog,
  ProviderId,
} from "./types.js";

const BEDROCK_PREFIXES = [
  "us.",
  "eu.",
  "ap.",
  "apac.",
  "ca.",
  "au.",
  "jp.",
  "us-gov.",
  "global.",
] as const;

export function createProviderCatalog<
  ProviderName extends string = string,
  ModelName extends string = string,
>(data: Provider): ProviderCatalog<ProviderName, ModelName> {
  return new ShardedProviderCatalog(data) as unknown as ProviderCatalog<
    ProviderName,
    ModelName
  >;
}

class ShardedProviderCatalog implements ProviderCatalog {
  readonly id: ProviderId;
  readonly data: Provider;
  readonly modelIds: readonly string[];
  readonly #models: readonly Model[];
  readonly #aliases = new Map<string, Model>();

  constructor(data: Provider) {
    this.id = data.id;
    this.data = data;
    this.modelIds = Object.keys(data.models);
    this.#models = Object.values(data.models);

    for (const model of this.#models) {
      for (const alias of model.aliases ?? []) {
        this.#aliases.set(alias, model);
      }
    }
  }

  get(modelId: string): Model {
    const model = this.find(modelId);

    if (model === undefined) {
      throw new ModelNotFoundError(this.id, modelId);
    }

    return model;
  }

  find(modelId: string): Model | undefined {
    const lookupId = this.#stripBedrockPrefix(modelId);
    const alias = this.#aliases.get(lookupId);

    if (alias !== undefined) {
      return alias;
    }

    return Object.hasOwn(this.data.models, lookupId)
      ? this.data.models[lookupId]
      : undefined;
  }

  has(modelId: string): boolean {
    return this.find(modelId) !== undefined;
  }

  models(): readonly Model[] {
    return this.#models;
  }

  #stripBedrockPrefix(modelId: string): string {
    if (this.id !== "amazon_bedrock") {
      return modelId;
    }

    const prefix = BEDROCK_PREFIXES.find((candidate) =>
      modelId.startsWith(candidate),
    );

    return prefix === undefined ? modelId : modelId.slice(prefix.length);
  }
}
