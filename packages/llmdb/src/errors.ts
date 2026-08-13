export class LLMDBError extends Error {}

export class InvalidModelSpecError extends LLMDBError {
  override readonly name = "InvalidModelSpecError";

  constructor(spec: string, reason: string) {
    super(`Invalid model spec ${JSON.stringify(spec)}: ${reason}`);
  }
}

export class ProviderNotFoundError extends LLMDBError {
  override readonly name = "ProviderNotFoundError";

  constructor(providerId: string) {
    super(`Unknown LLM provider: ${providerId}`);
  }
}

export class ModelNotFoundError extends LLMDBError {
  override readonly name = "ModelNotFoundError";

  constructor(providerId: string, modelId: string) {
    super(`Unknown LLM model: ${providerId}:${modelId}`);
  }
}
