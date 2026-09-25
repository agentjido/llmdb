import {
  llmdb,
  parseModelSpec,
  type EmbeddingCapability,
  type KnownProviderId,
  type Model,
  type Pricing,
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
const pricingModifier: PricingComponent = {
  id: "modifier.priority",
  kind: "other",
  unit: "other",
  multiplier: 1.5,
  applies_to: ["token.*"],
};
const groupedPricingComponent: PricingComponent = {
  id: "token.input.long",
  role: "rate",
  kind: "token",
  unit: "token",
  per: 1_000_000,
  rate: 2,
  rate_group: "input_tokens",
  rate_group_policy: "exactly_one",
};
({
  id: "token.invalid",
  kind: "token",
  unit: "token",
  // @ts-expect-error Pricing roles are a closed set.
  role: "discount",
} satisfies PricingComponent);
const creditPricing: Pricing = {
  currency: "credits",
  components: [minimalPricingComponent],
  excluded_cost_components: ["token.cache_write", "token.reasoning"],
};
const excludedComponents: readonly string[] | null | undefined =
  creditPricing.excluded_cost_components;

model.then((value) => value.capabilities?.tools.enabled);
models.then((values) => values.at(0)?.pricing?.components.at(0)?.rate);
providerIds.at(0);
parsed.providerId;
minimalPricingComponent.notes;
minimalEmbeddingCapability.min_dimensions;
excludedComponents?.at(0);
pricingModifier.multiplier;
groupedPricingComponent.role;
groupedPricingComponent.rate_group;
groupedPricingComponent.rate_group_policy;
