# Model Struct Evolution Proposal

This proposal describes how to evolve `%LLMDB.Model{}` and the build/runtime
pipeline so LLMDB can represent provider-published conditional pricing and richer
runtime capabilities without breaking existing consumers.

Status: phase 1 and current-model pricing overlays implemented. The runtime
contract supports the additive schema fields described here for limits, pricing
components, reasoning capabilities, provider capability groups, Anthropic
direct-source mapping, and conditional pricing component selection.

The curated overlays now cover GPT-6 Astra/Sol/Luna and Claude Fable 5.1,
Opus 5.5, Opus 5, Sonnet 5, and Haiku 4.5. They include context tiers where
published, cache durations, processing discounts/premiums, and applicable
regional uplifts. See [Pricing and Billing](pricing-and-billing.md) for the
implemented context contract and worked examples. The older model examples below
remain design illustrations, not a current price list.

The implementation uses token-wide modifiers for Batch/Flex/Fast and residency.
For derived cache rates, resolve the base rate first and apply each token-wide
modifier once to the resulting rate. This avoids applying the same discount or
uplift both through a dependency and directly. The selector returns applicable
metadata and unresolved conditions; final invoice calculation and validation of
provider-specific request eligibility remain consumer responsibilities.

## Why This Is Needed

Recent provider metadata has outgrown the current flat model shape:

- OpenAI publishes different token rates by context tier, service tier, Batch,
  Flex, Priority, and data residency. GPT-5.5 is the motivating example: the
  standard short-context rates are not the same as the long-context rates.
- OpenAI reasoning effort changes token usage and latency, while reasoning tokens
  are billed as output tokens rather than at a separate per-effort price.
- Anthropic's Models API publishes rich capability metadata for Claude Fable 5,
  including effort levels, adaptive thinking, batch support, code execution,
  citations, and context management.
- Anthropic pricing has condition-specific modifiers: prompt cache TTL, Batch API
  discounts, data residency multipliers, and fast mode on supported Opus models.
  Claude Fable 5 does not have OpenAI-style long-context tier pricing, but it
  still needs conditional pricing for cache TTL, Batch, and data residency.

The current model schema can store only a subset of this:

- `cost` is a flat legacy map.
- `pricing.components` can represent many billable components, but not when a
  component applies, whether it is a multiplier, or which request/provider mode
  activates it.
- `capabilities.reasoning` currently captures `enabled` and `token_budget`, but
  not effort levels, thinking modes, display behavior, or provider-specific
  context handling features.
- `limits` has `context` and `output`, but provider APIs often publish
  `max_input_tokens` separately.

## Source Authority

Use provider-direct sources first and third-party catalogs only as discovery
leads.

| Provider | Direct source to trust | What it can supply | What still needs docs or curated local metadata |
| --- | --- | --- | --- |
| OpenAI | `GET /v1/models` | Model inventory and basic ownership/created data | Pricing, context tiers, reasoning effort values/defaults, service tiers, data residency |
| Anthropic | `GET /v1/models` | Model inventory, display names, dates, token limits, capability tree | Pricing, lifecycle notes, aliases, cloud-specific caveats, retention/cross-model behavior |

For OpenAI and Anthropic, `models.dev` should not drive the schema shape. It can
still be useful as a fallback source or comparison point, but provider APIs and
official provider docs should decide which fields become canonical.

## Evidence Links

Official provider references used for this proposal:

- OpenAI Models API:
  <https://developers.openai.com/api/reference/resources/models/methods/list>
- OpenAI pricing:
  <https://developers.openai.com/api/docs/pricing>
- OpenAI reasoning models:
  <https://developers.openai.com/api/docs/guides/reasoning>
- Anthropic Models API:
  <https://platform.claude.com/docs/en/api/models/list>
- Anthropic pricing:
  <https://platform.claude.com/docs/en/about-claude/pricing>
- Anthropic prompt caching:
  <https://platform.claude.com/docs/en/build-with-claude/prompt-caching>
- Anthropic context windows:
  <https://platform.claude.com/docs/en/build-with-claude/context-windows>
- Claude Fable 5 and Mythos 5:
  <https://platform.claude.com/docs/en/about-claude/models/introducing-claude-fable-5-and-claude-mythos-5>

## Current Implementation Touchpoints

The implementation work should be planned around these existing boundaries:

- `lib/llm_db/model.ex` owns the `LLMDB.Model` struct and nested Zoi schemas.
- `lib/llm_db/provider.ex` owns provider-level `pricing_defaults`, which shares
  the pricing component shape and must be updated with model-level pricing.
- `lib/llm_db/pricing.ex` converts legacy `cost` maps into
  `pricing.components` and merges provider defaults at load time.
- `lib/llm_db/sources/openai.ex` maps OpenAI's direct `/v1/models` inventory.
- `lib/llm_db/sources/anthropic.ex` maps Anthropic's direct `/v1/models`
  inventory, limits, modalities, and a small subset of capabilities.
- `priv/llm_db/local/<provider>/*.toml` should remain the place for official
  docs-only facts such as pricing and lifecycle.
- `priv/llm_db/remote/*.json` should remain provider API cache data and should
  not be hand-edited.
- `priv/llm_db/providers/*.json` and `priv/llm_db/snapshot.json` should remain
  generated artifacts.

Important current behavior:

- `Zoi.parse/2` currently drops unknown nested keys in schemas such as
  `limits`, `capabilities.reasoning`, and `pricing.components`.
- Sparse overlay validation also preserves only schema-known keys.
- Therefore, the schema must be expanded before any source transform or local
  TOML starts emitting new canonical fields, or the data can be silently lost.
- Runtime pricing enrichment runs in `LLMDB.Loader` after packaged/custom models
  are validated, so new pricing fields must validate before
  `LLMDB.Pricing.apply_cost_components/1` sees them.

## Goals

- Preserve existing `%LLMDB.Model{}` field names and consumer access patterns.
- Represent conditional pricing without forcing every consumer to become a
  billing engine.
- Capture provider-published reasoning metadata in a typed, queryable form.
- Preserve provider raw capability data during schema transitions.
- Keep old snapshots and custom provider maps loadable.
- Allow incremental implementation through additive schema changes.

## Non-Goals

- Remove `cost` or change its meaning.
- Guarantee exact invoice calculation for every provider and contract.
- Encode private account discounts, negotiated enterprise pricing, or dashboard
  entitlements.
- Replace provider SDKs or API references for request validation.

## Proposed `%LLMDB.Model{}` Shape

The top-level struct should remain recognizable. The proposal is to extend
existing nested maps instead of replacing them.

```elixir
%LLMDB.Model{
  id: "claude-fable-5",
  provider: :anthropic,
  limits: %{
    context: 1_000_000,
    input: 1_000_000,
    output: 128_000
  },
  cost: %{
    input: 10.0,
    output: 50.0,
    cache_read: 1.0,
    cache_write: 12.5
  },
  capabilities: %{
    reasoning: %{
      enabled: true,
      effort: %{
        supported: true,
        values: ["low", "medium", "high", "xhigh", "max"],
        default: nil
      },
      thinking: %{
        types: ["adaptive"],
        default_type: "adaptive",
        disable_supported: false,
        raw_output_supported: false
      },
      token_budget: nil
    },
    batch: %{supported: true},
    citations: %{supported: true},
    code_execution: %{supported: true},
    context_management: %{
      supported: true,
      features: ["clear_thinking", "clear_tool_uses", "compact"]
    },
    json: %{schema: true},
    tools: %{enabled: true}
  },
  pricing: %{
    currency: "USD",
    merge: "merge_by_id",
    components: [
      %{
        id: "token.input",
        kind: "token",
        unit: "token",
        per: 1_000_000,
        rate: 10.0
      },
      %{
        id: "token.input.batch",
        kind: "token",
        unit: "token",
        per: 1_000_000,
        rate: 5.0,
        applies_when: %{api: "batch"}
      },
      %{
        id: "token.cache_write.1h",
        kind: "token",
        unit: "token",
        per: 1_000_000,
        meter: "cache_write_tokens",
        multiplier: 2.0,
        derives_from: "token.input",
        applies_when: %{cache_operation: "write", cache_ttl: "1h"}
      },
      %{
        id: "pricing.data_residency",
        kind: "other",
        unit: "other",
        multiplier: 1.1,
        applies_to: ["token.*"],
        applies_when: %{inference_geo: true}
      }
    ]
  },
  extra: %{
    provider_capabilities: %{...}
  }
}
```

### Compatibility Rules

- `cost` remains the default standard token rate surface. Consumers that only
  read `model.cost.input` or `model.cost.output` keep working.
- `limits.context` remains the broad maximum window used by existing consumers.
  `limits.input` is additive and should mirror provider-published input limits
  when available.
- `capabilities.reasoning.enabled` remains the coarse boolean. New nested
  reasoning fields refine it.
- Existing pricing components without `applies_when`, `multiplier`, or new
  metadata remain valid.
- Adding optional nested keys is preferred over adding many new top-level struct
  fields.

## Pricing Component Extensions

Extend `pricing.components` with optional fields:

```elixir
%{
  id: "token.input.long_context",
  kind: "token",
  unit: "token",
  per: 1_000_000,
  rate: 10.0,
  multiplier: nil,
  derives_from: nil,
  applies_to: nil,
  applies_when: %{input_tokens: %{gt: 272_000}},
  excludes_when: nil,
  meter: "input_tokens",
  mode: "standard",
  charge_scope: "full_request",
  source: "provider_docs",
  notes: "OpenAI GPT-5.5 long-context input rate"
}
```

Recommended semantics:

- `rate` is an absolute price in `pricing.currency`.
- `multiplier` is a factor applied to one or more matched components, or a
  factor used to derive this component from another component.
- `derives_from` identifies a base component ID used to calculate this
  component's rate. This is useful for prompt-cache write/read rates that are
  published as a multiplier of the active input-token rate.
- `applies_to` identifies component IDs or prefixes that a modifier component
  affects. Entries match exact component IDs unless they end in `.*`; reserve
  prefixes such as `"token.*"` for provider-wide multipliers.
- `applies_when` is a provider-neutral condition map.
- `excludes_when` is optional and should be rare; prefer positive selectors.
- `charge_scope` distinguishes full-request tier pricing from marginal overage
  pricing. Use `"full_request"` for provider rules where crossing a threshold
  changes the rate for all request/session tokens, not just tokens over the
  threshold.
- `source` should identify the evidence layer, not a full citation system. Use
  values such as `"provider_api"`, `"provider_docs"`, `"local_override"`, or
  `"provider_default"`.
- `notes` remains human-readable and non-authoritative.

Component classes:

- **Base rate components** have `rate` and no `applies_when`, such as
  `token.input`.
- **Conditional rate components** have `rate` and `applies_when`, such as
  `token.input.long_context`.
- **Derived rate components** have `derives_from` and `multiplier`, such as
  Anthropic cache writes derived from the active input-token rate.
- **Modifier components** have `multiplier` and `applies_to`, such as data
  residency uplifts.

Do not encode a stackable provider multiplier only as a fixed absolute rate
unless every supported combination is enumerated. For example, Anthropic prompt
cache TTL multipliers stack with Batch API discounts and data residency, so a
1-hour cache write should be represented as `2.0 * active token.input`, not only
as `$20 / MTok` for Claude Fable 5 standard requests.

Recommended condition keys:

| Key | Example | Use |
| --- | --- | --- |
| `api` | `%{api: "batch"}` | Batch API or provider-specific async batch mode |
| `service_tier` | `%{service_tier: "priority"}` | OpenAI Priority or other service tier rates |
| `processing_mode` | `%{processing_mode: "flex"}` | Flex, background, or similar processing modes |
| `input_tokens` | `%{input_tokens: %{gt: 272_000}}` | Long-context tiers |
| `cache_operation` | `%{cache_operation: "write"}` | Cache read/write billing meters |
| `cache_ttl` | `%{cache_ttl: "1h"}` | Prompt cache write duration |
| `inference_geo` | `%{inference_geo: true}` | Data residency/regional processing uplifts |
| `request_body` | `%{request_body: %{speed: "fast"}}` | Provider request body switches |
| `request_headers` | `%{request_headers: %{"anthropic-beta" => "fast-mode-2026-02-01"}}` | Provider beta/header switches |

Keep component IDs unique. The current merge behavior uses `id`, so conditional
variants should be named explicitly:

- `token.input`
- `token.input.long_context`
- `token.input.batch`
- `token.input.priority`
- `token.cache_write.5m`
- `token.cache_write.1h`
- `pricing.data_residency`

This avoids changing `merge_by_id` in the first implementation phase.

## Reasoning Capability Extensions

Extend the current reasoning schema from:

```elixir
%{enabled: true, token_budget: 10_000}
```

to:

```elixir
%{
  enabled: true,
  effort: %{
    supported: true,
    values: ["none", "low", "medium", "high", "xhigh"],
    default: "medium"
  },
  thinking: %{
    types: ["adaptive", "enabled"],
    default_type: "adaptive",
    disable_supported: false,
    raw_output_supported: false,
    summary_supported: true,
    encrypted_supported: true
  },
  token_budget: %{
    min: 1_024,
    max: nil,
    default: nil
  }
}
```

Notes:

- OpenAI GPT-5.5 effort is a request control. It changes expected output token
  usage and latency, but it does not publish separate per-effort token rates.
- Anthropic Claude Fable 5 uses adaptive thinking as the only thinking mode and
  publishes effort support in the Models API.
- `token_budget` should stay backward compatible with the current integer form.
  Loaders should accept both `token_budget: 10_000` and the richer map form.

## Provider Examples

### OpenAI GPT-5.5

OpenAI's direct model endpoint supplies inventory, not pricing. Official OpenAI
docs supply pricing, context tiers, service tiers, and reasoning behavior.

Proposed capture:

```elixir
%{
  cost: %{input: 5.0, output: 30.0, cache_read: 0.5},
  limits: %{context: 1_050_000, input: 1_050_000, output: 128_000},
  capabilities: %{
    reasoning: %{
      enabled: true,
      effort: %{
        supported: true,
        values: ["none", "low", "medium", "high", "xhigh"],
        default: "medium"
      }
    }
  },
  pricing: %{
    components: [
      %{id: "token.input", kind: "token", unit: "token", per: 1_000_000, rate: 5.0},
      %{id: "token.output", kind: "token", unit: "token", per: 1_000_000, rate: 30.0},
      %{id: "token.cache_read", kind: "token", unit: "token", per: 1_000_000, rate: 0.5},
      %{
        id: "token.input.long_context",
        kind: "token",
        unit: "token",
        per: 1_000_000,
        rate: 10.0,
        applies_when: %{input_tokens: %{gt: 272_000}},
        charge_scope: "full_request"
      },
      %{
        id: "token.output.long_context",
        kind: "token",
        unit: "token",
        per: 1_000_000,
        rate: 45.0,
        applies_when: %{input_tokens: %{gt: 272_000}},
        charge_scope: "full_request"
      },
      %{
        id: "token.input.priority",
        kind: "token",
        unit: "token",
        per: 1_000_000,
        rate: 12.5,
        applies_when: %{service_tier: "priority"}
      }
    ]
  }
}
```

The first implementation should not create separate pricing for each reasoning
effort. It should expose effort values under capabilities and let consumers
estimate cost from measured or expected output/reasoning token counts.

### Anthropic Claude Fable 5

Anthropic's direct Models API supplies the capability tree and token limits.
Official Anthropic docs supply pricing.

Proposed capture:

```elixir
%{
  cost: %{input: 10.0, output: 50.0, cache_read: 1.0, cache_write: 12.5},
  limits: %{context: 1_000_000, input: 1_000_000, output: 128_000},
  capabilities: %{
    reasoning: %{
      enabled: true,
      effort: %{
        supported: true,
        values: ["low", "medium", "high", "xhigh", "max"],
        default: nil
      },
      thinking: %{
        types: ["adaptive"],
        default_type: "adaptive",
        disable_supported: false,
        raw_output_supported: false
      }
    },
    batch: %{supported: true},
    citations: %{supported: true},
    code_execution: %{supported: true},
    context_management: %{supported: true}
  },
  pricing: %{
    components: [
      %{id: "token.input", kind: "token", unit: "token", per: 1_000_000, rate: 10.0},
      %{id: "token.output", kind: "token", unit: "token", per: 1_000_000, rate: 50.0},
      %{id: "token.cache_read", kind: "token", unit: "token", per: 1_000_000, rate: 1.0},
      %{
        id: "token.cache_read.derived",
        kind: "token",
        unit: "token",
        per: 1_000_000,
        meter: "cache_read_tokens",
        multiplier: 0.1,
        derives_from: "token.input",
        applies_when: %{cache_operation: "read"}
      },
      %{
        id: "token.cache_write.5m",
        kind: "token",
        unit: "token",
        per: 1_000_000,
        meter: "cache_write_tokens",
        multiplier: 1.25,
        derives_from: "token.input",
        applies_when: %{cache_operation: "write", cache_ttl: "5m"}
      },
      %{
        id: "token.cache_write.1h",
        kind: "token",
        unit: "token",
        per: 1_000_000,
        meter: "cache_write_tokens",
        multiplier: 2.0,
        derives_from: "token.input",
        applies_when: %{cache_operation: "write", cache_ttl: "1h"}
      },
      %{
        id: "token.input.batch",
        kind: "token",
        unit: "token",
        per: 1_000_000,
        rate: 5.0,
        applies_when: %{api: "batch"}
      },
      %{
        id: "token.output.batch",
        kind: "token",
        unit: "token",
        per: 1_000_000,
        rate: 25.0,
        applies_when: %{api: "batch"}
      },
      %{
        id: "pricing.data_residency",
        kind: "other",
        unit: "other",
        multiplier: 1.1,
        applies_to: ["token.*"],
        applies_when: %{inference_geo: true}
      }
    ]
  }
}
```

Do not add a Fable long-context premium component unless Anthropic publishes one.
Current docs say the full 1M context window is standard pricing.

## Pipeline Changes

### 1. Source Pull

- Keep existing remote cache behavior.
- Do not hand-edit remote caches.
- Treat provider APIs as authoritative for fields they publish.
- Preserve raw provider capability trees in cache exactly as received.

### 2. Source Transform

Source modules should map provider API fields into the richer canonical shape:

- Anthropic:
  - `max_input_tokens` -> `limits.input` and `limits.context`
  - `max_tokens` -> `limits.output`
  - `capabilities.effort` -> `capabilities.reasoning.effort`
  - `capabilities.thinking.types` -> `capabilities.reasoning.thinking`
  - `batch`, `citations`, `code_execution`, `context_management` -> typed
    `capabilities`
  - Preserve original `capabilities` under `extra.provider_capabilities` until
    coverage is complete.
- OpenAI:
  - Continue using `/v1/models` for inventory.
  - Keep pricing/reasoning facts in curated local overlays sourced from official
    OpenAI docs, because `/v1/models` does not publish those details.

### 3. Normalize

- Normalize nested map keys without atom leaks.
- Accept both atom and string keys for new nested fields.
- Normalize modality and capability enum values to strings or atoms according to
  existing conventions, but avoid inventing atoms from untrusted runtime input.

### 4. Validate

Add optional Zoi schemas for:

- `limits.input`
- `capabilities.reasoning.effort`
- `capabilities.reasoning.thinking`
- richer `capabilities.batch`, `capabilities.citations`,
  `capabilities.code_execution`, and `capabilities.context_management`
- `pricing.components[].applies_when`
- `pricing.components[].excludes_when`
- `pricing.components[].multiplier`
- `pricing.components[].derives_from`
- `pricing.components[].applies_to`
- `pricing.components[].charge_scope`
- `pricing.components[].source`

Validation should remain permissive for unknown provider-specific condition keys
inside `applies_when` so new provider pricing modes do not require immediate
library releases.

### 5. Merge

- Keep current last-source-wins precedence.
- Keep list merge behavior unless explicitly changed.
- Preserve `cost` as flat standard pricing.
- Merge `pricing.components` by `id` as today. Conditional variants should use
  unique IDs.
- Deep-merge nested capability maps so local curated docs can add defaults or
  caveats without replacing provider API capability trees.

### 6. Enrich

- Continue synthesizing `pricing.components` from `cost`.
- Only generate unconditional standard token components from `cost`.
- Do not synthesize conditional components unless there is explicit provider
  evidence.
- Populate coarse booleans from rich capability maps:
  - `capabilities.reasoning.enabled = true` when any effort/thinking support is
    present.
  - `capabilities.tools.enabled = true` remains independent of code execution or
    provider-hosted tools.
- Keep provider-level pricing defaults and merge them after model pricing.
- Do not apply conditional pricing during enrichment. Enrichment should preserve
  metadata; pricing selection belongs in an explicit helper or downstream
  billing code.

### 7. Snapshot Build

- Generated `priv/llm_db/providers/*.json` and `priv/llm_db/snapshot.json`
  should include optional fields only when present.
- Old snapshots without new fields must load unchanged.
- New snapshots should still include legacy `cost` where the provider publishes
  simple standard token rates.
- Before publishing a snapshot that contains new canonical fields, test that the
  minimum supported package version can either load the snapshot or fails with a
  clear compatibility error. If older packages silently strip important fields,
  add a snapshot metadata gate such as `min_reader_version` before publishing the
  new shape through the public snapshot channel.

### 8. Runtime Load

- `LLMDB.Loader` should deserialize old and new shapes.
- `LLMDB.Pricing.apply_cost_components/1` should remain idempotent and avoid
  overwriting explicit conditional components.
- Consumers should be able to ignore `applies_when` and still read base rates.
- Custom provider overlays must accept the new shape only after schema support is
  in place; otherwise `validate_model_overlay/1` can strip the new fields before
  merge.

### 9. Query Helpers

After the data shape is stable, add optional helpers rather than forcing pricing
calculation into the struct:

```elixir
LLMDB.Pricing.components_for(model,
  api: "batch",
  input_tokens: 900_000,
  cache_ttl: "1h",
  inference_geo: "us"
)
```

This keeps `%LLMDB.Model{}` as metadata and lets billing logic evolve
independently.

The helper should return both selected components and unresolved modifiers when
conditions are incomplete. Silent best guesses are worse than partial answers for
billing.

## Backward Compatibility Plan

1. Add new schema fields as optional.
2. Keep `cost` and automatic `cost` -> `pricing.components` conversion.
3. Keep old `token_budget` integer support while accepting the richer map.
4. Keep `limits.context` as the primary broad context field.
5. Keep `capabilities.reasoning.enabled` and existing capability booleans.
6. Preserve unknown provider fields in `extra`.
7. Use unique component IDs so existing `merge_by_id` remains valid.
8. Avoid changing public APIs in the first implementation PR.
9. Add tests that construct old-format models and new-format models through
   `LLMDB.Model.new/1`, source transforms, snapshot loading, and runtime custom
   providers.
10. Add regression tests proving unknown new fields are not stripped after the
    schema PR lands.

## Risk Register

| Risk | Mitigation |
| --- | --- |
| New fields are emitted before schema support and silently stripped | Land schema and validation support before source/local overlay changes |
| Conditional pricing is treated as marginal when provider docs mean full-request pricing | Capture `charge_scope` and test GPT-5.5 long-context selection |
| Stackable modifiers are encoded as fixed rates | Use `derives_from`, `multiplier`, and `applies_to` for cache TTL and data residency cases |
| Old consumers fetch new snapshots and lose important metadata | Add snapshot compatibility tests and a `min_reader_version` gate if needed |
| Provider capability booleans become ambiguous | Preserve coarse booleans and add richer nested fields rather than replacing existing fields |
| Provider docs change after metadata is encoded | Keep source URLs in local overlays or docs notes and make provider verification repeatable |
| Atom leaks from provider-specific condition keys | Keep condition keys as strings unless they are part of a small canonical allowlist |

## Test Matrix

Implementation PRs should add coverage at these layers:

- `LLMDB.Model.new/1` accepts old and new model maps.
- `LLMDB.Provider.new/1` accepts provider pricing defaults with new component
  fields.
- `LLMDB.Validate.validate_model_overlay/1` preserves new sparse overlay fields.
- `LLMDB.Sources.Anthropic.transform/1` maps direct API capabilities without
  dropping raw provider capability data.
- `LLMDB.Pricing.apply_cost_components/1` keeps legacy generated components and
  preserves explicit conditional/derived components.
- Snapshot load accepts old snapshots and new snapshots.
- Runtime custom providers can define new pricing/capability fields.
- Pricing helper selection handles:
  - GPT-5.5 short-context standard pricing
  - GPT-5.5 long-context full-request pricing
  - GPT-5.5 Priority pricing
  - Claude Fable 5 standard pricing
  - Claude Fable 5 Batch pricing
  - Claude Fable 5 1-hour cache write derived from active input rate
  - data residency multiplier stacking

## Implementation Sequence

Recommended PR breakdown:

1. **Schema-only compatibility PR**
   - Add optional Zoi schemas.
   - Add loader support for old and new `token_budget`.
   - Add tests showing old model maps still validate.
2. **Pricing component condition PR**
   - Add `applies_when`, `excludes_when`, `multiplier`, and `source`.
   - Update pricing docs.
   - Add component selection helper behind a new API.
3. **Anthropic direct-source PR**
   - Map the direct Models API capability tree.
   - Preserve `extra.provider_capabilities`.
   - Add Fable and Opus/Sonnet tests from cached API fixtures.
4. **OpenAI curated overlay PR**
   - Encode GPT-5.5 long-context, Batch, Flex, Priority, and data-residency
     components from official OpenAI docs.
   - Encode reasoning effort values/defaults from official OpenAI docs.
5. **Anthropic pricing overlay PR**
   - Encode cache TTL, Batch, data residency, and fast mode where officially
     documented.
   - Explicitly omit long-context premium for Fable unless docs change.
6. **Consumer API PR**
   - Add query helpers and examples for choosing active pricing components.
   - Keep raw metadata access unchanged.

## Acceptance Criteria

- Existing consumers reading `model.cost`, `model.limits.context`,
  `model.capabilities.reasoning.enabled`, and `model.pricing.components` continue
  to work.
- Old snapshots and custom provider maps load without migration steps.
- Fable exposes effort and adaptive-thinking metadata from Anthropic's direct
  Models API.
- GPT-5.5 exposes long-context pricing without pretending reasoning effort has a
  separate per-effort token rate.
- Conditional pricing components can represent OpenAI context tiers and Anthropic
  cache TTL/Batch/data-residency cases.
- Provider docs and direct APIs remain the evidence source for OpenAI and
  Anthropic changes.
