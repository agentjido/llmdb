import {
  llmdb,
  parseModelSpec,
  type EmbeddingCapability,
  type KnownProviderId,
  type Model,
  type PricingComponent,
} from "../src/index.js";

const providerId: KnownProviderId = "openai";
const providerIds: readonly KnownProviderId[] = llmdb.providerIds();
const model: Promise<Model> = llmdb.get("openai:gpt-5.4");
const models: Promise<readonly Model[]> = llmdb.models(providerId);
const parsed = parseModelSpec("gpt-5.4@openai");
const minimalPricingComponent: PricingComponent = {
  id: "token.input",
  kind: "token",
  unit: "token",
  per: 1_000_000,
  rate: 1,
};
const minimalEmbeddingCapability: EmbeddingCapability = {};

model.then((value) => value.capabilities?.tools.enabled);
models.then((values) => values.at(0)?.pricing?.components.at(0)?.rate);
providerIds.at(0);
parsed.providerId;
minimalPricingComponent.notes;
minimalEmbeddingCapability.min_dimensions;
