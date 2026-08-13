export type JsonPrimitive = boolean | number | string | null;

export type JsonValue =
  | JsonPrimitive
  | readonly JsonValue[]
  | { readonly [key: string]: JsonValue };

export type ProviderId = string;
export type ModelId = string;

export interface ConfigField {
  readonly name: string;
  readonly type: string;
  readonly required?: boolean;
  readonly default?: JsonValue;
  readonly doc?: string | null;
}

export interface PricingComponent {
  readonly id: string;
  readonly kind:
    | "token"
    | "tool"
    | "image"
    | "storage"
    | "request"
    | "other"
    | null;
  readonly unit:
    | "token"
    | "call"
    | "query"
    | "session"
    | "gb_day"
    | "image"
    | "source"
    | "other"
    | null;
  readonly per: number | null;
  readonly rate: number | null;
  readonly meter?: string | null;
  readonly tool?: string | null;
  readonly size_class?: string | null;
  readonly multiplier?: number | null;
  readonly derives_from?: string | null;
  readonly applies_to?: readonly string[] | null;
  readonly applies_when?: Readonly<Record<string, JsonValue>> | null;
  readonly excludes_when?: Readonly<Record<string, JsonValue>> | null;
  readonly mode?: string | null;
  readonly charge_scope?: string | null;
  readonly source?: string | null;
  readonly notes?: string | null;
  readonly [key: string]: unknown;
}

export interface Pricing {
  readonly currency: string | null;
  readonly components: readonly PricingComponent[];
  readonly merge?: "replace" | "merge_by_id";
  readonly [key: string]: unknown;
}

export interface RuntimeAuthHeader {
  readonly name: string;
  readonly env?: string | null;
  readonly value?: string | null;
}

export interface RuntimeAuth {
  readonly type?:
    | "bearer"
    | "x_api_key"
    | "header"
    | "query"
    | "multi_header"
    | null;
  readonly env?: readonly string[];
  readonly header_name?: string | null;
  readonly query_name?: string | null;
  readonly headers?: readonly RuntimeAuthHeader[];
}

export interface RuntimeExecution {
  readonly text?: string | null;
  readonly object?: string | null;
  readonly embed?: string | null;
  readonly image?: string | null;
  readonly transcription?: string | null;
  readonly speech?: string | null;
  readonly realtime?: string | null;
}

export interface ProviderRuntime {
  readonly base_url: string | null;
  readonly auth: RuntimeAuth | null;
  readonly default_headers: Readonly<Record<string, JsonValue>>;
  readonly default_query: Readonly<Record<string, JsonValue>>;
  readonly config_schema: readonly ConfigField[] | null;
  readonly doc_url: string | null;
  readonly execution?: RuntimeExecution | null;
}

export interface ModelLimits {
  readonly context?: number | null;
  readonly input?: number | null;
  readonly output?: number | null;
}

export interface ModelCost {
  readonly input?: number | null;
  readonly output?: number | null;
  readonly request?: number | null;
  readonly cache_read?: number | null;
  readonly cache_write?: number | null;
  readonly training?: number | null;
  readonly reasoning?: number | null;
  readonly image?: number | null;
  readonly audio?: number | null;
  readonly input_audio?: number | null;
  readonly output_audio?: number | null;
  readonly input_video?: number | null;
  readonly output_video?: number | null;
}

export interface ModelModalities {
  readonly input: readonly string[] | null;
  readonly output: readonly string[] | null;
}

export interface ReasoningEffort {
  readonly supported?: boolean;
  readonly values?: readonly string[];
  readonly default?: string | null;
}

export interface ReasoningThinking {
  readonly supported?: boolean;
  readonly types?: readonly string[];
  readonly default_type?: string | null;
  readonly disable_supported?: boolean | null;
  readonly raw_output_supported?: boolean | null;
  readonly summary_supported?: boolean | null;
  readonly encrypted_supported?: boolean | null;
}

export interface TokenBudget {
  readonly min?: number | null;
  readonly max?: number | null;
  readonly default?: number | null;
}

export interface ReasoningCapability {
  readonly enabled: boolean | null;
  readonly effort?: ReasoningEffort | null;
  readonly thinking?: ReasoningThinking | null;
  readonly token_budget?: number | TokenBudget | null;
}

export interface ToolCapability {
  readonly enabled?: boolean | null;
  readonly streaming?: boolean | null;
  readonly strict?: boolean | null;
  readonly parallel?: boolean | null;
  readonly forced_choice?: boolean | null;
}

export interface JsonCapability {
  readonly native?: boolean | null;
  readonly schema?: boolean | null;
  readonly strict?: boolean | null;
}

export interface SupportedFeature {
  readonly supported?: boolean;
  readonly features?: readonly string[];
}

export interface EmbeddingCapability {
  readonly min_dimensions?: number | null;
  readonly max_dimensions?: number | null;
  readonly default_dimensions?: number | null;
}

export interface ModelCapabilities {
  readonly chat: boolean;
  readonly embeddings: boolean | EmbeddingCapability;
  readonly reasoning: ReasoningCapability;
  readonly rerank: boolean;
  readonly tools: ToolCapability;
  readonly json: JsonCapability;
  readonly caching?: { readonly type: "implicit" | "explicit" | null } | null;
  readonly streaming: {
    readonly text?: boolean | null;
    readonly tool_calls?: boolean | null;
  };
  readonly batch?: SupportedFeature | null;
  readonly citations?: SupportedFeature | null;
  readonly code_execution?: SupportedFeature | null;
  readonly context_management?: SupportedFeature | null;
  readonly [key: string]: unknown;
}

export interface ModelLifecycle {
  readonly status?: "active" | "deprecated" | "retired" | null;
  readonly deprecated_at?: string | null;
  readonly retires_at?: string | null;
  readonly replacement?: string | null;
}

export interface ExecutionOperation {
  readonly supported: boolean;
  readonly family?: string | null;
  readonly wire_protocol?: string | null;
  readonly transport?: string | null;
  readonly provider_model_id?: string | null;
  readonly base_url?: string | null;
  readonly path?: string | null;
}

export interface ModelExecution {
  readonly text?: ExecutionOperation | null;
  readonly object?: ExecutionOperation | null;
  readonly embed?: ExecutionOperation | null;
  readonly image?: ExecutionOperation | null;
  readonly transcription?: ExecutionOperation | null;
  readonly speech?: ExecutionOperation | null;
  readonly realtime?: ExecutionOperation | null;
}

export interface Model {
  readonly id: ModelId;
  readonly model: string | null;
  readonly provider: ProviderId;
  readonly provider_model_id: string | null;
  readonly name: string | null;
  readonly family: string | null;
  readonly doc_url?: string | null;
  readonly release_date: string | null;
  readonly last_updated: string | null;
  readonly knowledge: string | null;
  readonly base_url: string | null;
  readonly limits: ModelLimits | null;
  readonly cost: ModelCost | null;
  readonly pricing: Pricing | null;
  readonly modalities: ModelModalities | null;
  readonly capabilities: ModelCapabilities | null;
  readonly tags: readonly string[] | null;
  readonly deprecated: boolean;
  readonly retired: boolean;
  readonly lifecycle: ModelLifecycle | null;
  readonly execution?: ModelExecution | null;
  readonly catalog_only?: boolean;
  readonly aliases: readonly string[];
  readonly extra: Readonly<Record<string, JsonValue>> | null;
  readonly [key: string]: unknown;
}

export interface Provider {
  readonly id: ProviderId;
  readonly name: string | null;
  readonly base_url: string | null;
  readonly env: readonly string[] | null;
  readonly config_schema: readonly ConfigField[] | null;
  readonly doc: string | null;
  readonly exclude_models: readonly string[] | null;
  readonly pricing_defaults: Pricing | null;
  readonly runtime?: ProviderRuntime | null;
  readonly catalog_only?: boolean;
  readonly extra: Readonly<Record<string, JsonValue>> | null;
  readonly alias_of: ProviderId | null;
  readonly models: Readonly<Record<ModelId, Model>>;
  readonly [key: string]: unknown;
}

export interface Snapshot {
  readonly schema_version: 1;
  readonly version: number;
  readonly generated_at: string;
  readonly snapshot_id: string;
  readonly providers: Readonly<Record<ProviderId, Provider>>;
}

export interface ParsedModelSpec {
  readonly providerId: ProviderId;
  readonly modelId: ModelId;
}

export type ModelSpec = string | ParsedModelSpec;

export interface ProviderSummary {
  readonly id: ProviderId;
  readonly name: string | null;
  readonly base_url: string | null;
  readonly doc: string | null;
  readonly alias_of: ProviderId | null;
  readonly catalog_only: boolean;
  readonly model_count: number;
}

export interface Manifest {
  readonly format_version: 1;
  readonly snapshot_schema_version: 1;
  readonly catalog_version: number;
  readonly generated_at: string;
  readonly snapshot_id: string;
  readonly provider_count: number;
  readonly model_count: number;
  readonly providers: Readonly<Record<ProviderId, ProviderSummary>>;
}

export type OpenString<Known extends string> =
  | Known
  | (string & Record<never, never>);

export interface ProviderCatalog<
  ProviderName extends string = string,
  ModelName extends string = string,
> {
  readonly id: ProviderName;
  readonly data: Provider;
  readonly modelIds: readonly ModelName[];
  get(modelId: OpenString<ModelName>): Model;
  find(modelId: string): Model | undefined;
  has(modelId: string): boolean;
  models(): readonly Model[];
}

export interface FullCatalog {
  readonly manifest: Manifest;
  providerIds(): readonly ProviderId[];
  provider(providerId: ProviderId): ProviderCatalog;
  findProvider(providerId: ProviderId): ProviderCatalog | undefined;
  get(spec: ModelSpec): Model;
  find(spec: ModelSpec): Model | undefined;
  models(providerId?: ProviderId): readonly Model[];
}

export interface LLMDBClient<ProviderName extends string = string> {
  readonly manifest: Manifest;
  providerIds(): readonly ProviderName[];
  provider(
    providerId: OpenString<ProviderName>,
  ): Promise<ProviderCatalog>;
  findProvider(
    providerId: OpenString<ProviderName>,
  ): Promise<ProviderCatalog | undefined>;
  get(spec: ModelSpec): Promise<Model>;
  find(spec: ModelSpec): Promise<Model | undefined>;
  models(
    providerId: OpenString<ProviderName>,
  ): Promise<readonly Model[]>;
  preload(providerIds: readonly OpenString<ProviderName>[]): Promise<void>;
}

export type ProviderLoader = () => Promise<ProviderCatalog>;
