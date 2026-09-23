# Pricing and Billing

Query and manage pricing data for LLM models, including token costs, tool usage, and storage fees.

## Overview

LLMDB provides a flexible pricing system that supports:

- **Token-based pricing** - Input, output, cache, and reasoning tokens
- **Tool pricing** - Per-call fees for web search, code interpreter, file search, etc.
- **Storage pricing** - Per-GB-day fees for file storage
- **Image/media pricing** - Per-image or per-token fees for multimodal content
- **Conditional pricing** - Context tiers, service tiers, Batch API discounts,
  cache TTLs, and other provider-specific billing conditions

The pricing system has two layers:

1. **Legacy `cost` field** - Simple per-million-token pricing (input, output, cache, reasoning)
2. **New `pricing` field** - Component-based pricing with full flexibility

Legacy `cost` data is automatically converted to `pricing.components` at load time, ensuring backward compatibility.

## Pricing Components

Each pricing component describes a single billable item with the following fields:

```elixir
%{
  id: "token.input",           # Unique identifier
  kind: "token",               # Category: token, tool, image, storage, request, other
  unit: "token",               # Unit type: token, call, query, session, gb_day, image, source, other
  per: 1_000_000,              # Rate denominator (e.g., per 1M tokens)
  rate: 3.0,                   # Cost in currency units
  meter: "input_tokens",       # Optional: billing meter name
  tool: "web_search",          # Optional: tool name (for kind: "tool")
  size_class: "1024x1024",     # Optional: size variant (for images)
  multiplier: 1.1,             # Optional: multiplier for derived/modifier pricing
  derives_from: "token.input", # Optional: base component for derived rates
  applies_to: ["token.*"],     # Optional: component ids/prefixes affected by modifier
  applies_when: %{api: "batch"},       # Optional: conditions that activate this component
  excludes_when: %{region: "legacy"},  # Optional: conditions that suppress it
  mode: "standard",            # Optional: provider/request mode label
  charge_scope: "full_request",# Optional: full_request vs marginal semantics
  source: "provider_docs",     # Optional: provider_api, provider_docs, local_override, ...
  notes: "Cached tokens"       # Optional: human-readable notes
}
```

### Component Kinds

| Kind | Description | Common Units |
|------|-------------|--------------|
| `token` | Token-based billing | `token` |
| `tool` | Tool/feature usage | `call`, `query`, `session` |
| `image` | Image generation/processing | `image` |
| `storage` | Data storage fees | `gb_day` |
| `request` | Per-request fees | `call` |
| `other` | Custom billing types | varies |

### Standard Component IDs

Token components use the `token.*` prefix:

- `token.input` - Input tokens
- `token.output` - Output tokens
- `token.cache_read` - Cached input tokens (read)
- `token.cache_write` - Tokens written to cache
- `token.reasoning` - Reasoning/thinking tokens

Tool components use the `tool.*` prefix:

- `tool.web_search` - Web search calls
- `tool.file_search` - File search calls
- `tool.code_interpreter` - Code interpreter sessions

## Provider Defaults

Providers can define default pricing for tools and features that apply to all their models. This avoids duplicating tool pricing across every model definition.

### TOML Configuration

```toml
# priv/llm_db/local/openai/provider.toml
[pricing_defaults]
currency = "USD"

[[pricing_defaults.components]]
id = "tool.web_search"
kind = "tool"
tool = "web_search"
unit = "call"
per = 1000
rate = 10.0

[[pricing_defaults.components]]
id = "tool.file_search"
kind = "tool"
tool = "file_search"
unit = "call"
per = 1000
rate = 2.5

[[pricing_defaults.components]]
id = "storage.file_search"
kind = "storage"
unit = "gb_day"
per = 1
rate = 0.10
meter = "file_search_storage_gb_day"

[[pricing_defaults.components]]
id = "tool.code_interpreter"
kind = "tool"
tool = "code_interpreter"
unit = "session"
per = 1
rate = 0.03
```

### Built-in Provider Defaults

| Provider | Tools | Notes |
|----------|-------|-------|
| OpenAI | `web_search`, `web_search_preview`, `file_search`, `code_interpreter` | Plus file search storage |
| Anthropic | `web_search` | $10/1000 calls |
| Google | `web_search` | $35/1000 calls |
| xAI | `web_search`, `x_search`, `code_execution`, `document_search`, `collections_search` | Various rates |

### How Defaults Are Applied

Provider defaults are merged with model pricing at load time:

1. Models without `pricing` inherit the full provider defaults
2. Models with `pricing` merge components by ID (default) or replace entirely

```
Provider defaults + Model overrides = Final model.pricing
```

## Merge Strategies

When a model defines its own `pricing`, you can control how it combines with provider defaults using the `merge` field.

### merge_by_id (Default)

Merges components by their `id`. Model components override matching defaults; non-matching defaults are preserved.
Source layers and runtime model overlays also merge pricing by component ID, so
a docs-only modifier does not discard provider API context rates. A matching ID
replaces the entire component, including its conditions. Use `merge = "replace"`
to discard lower-precedence pricing components deliberately.

```elixir
# Provider default
%{id: "tool.web_search", rate: 10.0}

# Model override
%{pricing: %{
  merge: "merge_by_id",
  components: [%{id: "tool.web_search", rate: 5.0}]  # Override rate
}}

# Result: web_search at $5/1000, other provider defaults preserved
```

### replace

Completely replaces provider defaults with model-specific pricing.

```elixir
# Model with custom pricing only
%{pricing: %{
  merge: "replace",
  components: [
    %{id: "token.input", kind: "token", unit: "token", per: 1_000_000, rate: 1.0}
  ]
}}

# Result: Only token.input component, no provider defaults
```

### TOML Example

```toml
# Model with discounted web search
[pricing]
merge = "merge_by_id"

[[pricing.components]]
id = "tool.web_search"
kind = "tool"
tool = "web_search"
unit = "call"
per = 1000
rate = 5.0  # 50% discount from provider default
```

## Querying Pricing Data

### Access Model Pricing

```elixir
{:ok, model} = LLMDB.model("openai:gpt-4o")

# Full pricing structure
model.pricing
# => %{
#      currency: "USD",
#      components: [
#        %{id: "token.input", kind: "token", unit: "token", per: 1_000_000, rate: 2.5},
#        %{id: "token.output", kind: "token", unit: "token", per: 1_000_000, rate: 10.0},
#        %{id: "tool.web_search", kind: "tool", tool: "web_search", unit: "call", per: 1000, rate: 10.0},
#        ...
#      ]
#    }

# Legacy cost field (still available)
model.cost
# => %{input: 2.5, output: 10.0, ...}
```

### Find Specific Components

```elixir
# Get token input rate
input_component = Enum.find(model.pricing.components, & &1.id == "token.input")
input_component.rate  # => 2.5

# Get all tool pricing
tool_components = Enum.filter(model.pricing.components, & &1.kind == "tool")

# Check if model has web search pricing
has_web_search = Enum.any?(model.pricing.components, & &1.tool == "web_search")
```

### Select Conditional Components

Use `LLMDB.Pricing.components_for/2` when pricing data includes `applies_when`
or `excludes_when`. The helper selects components whose conditions are fully
satisfied and returns unresolved components separately when the supplied context
is incomplete.

```elixir
selection =
  LLMDB.Pricing.components_for(model,
    api: "batch",
    input_tokens: 900_000,
    cache_ttl: "1h",
    inference_geo: "us"
  )

selection.components
# => components that apply for this context

selection.unresolved
# => components that need more request context before they can be applied
```

The helper does not calculate invoices. It preserves the distinction between
base rates, conditional rates, derived rates, and stackable modifiers so billing
logic can make provider-specific choices explicitly.

### Curated conditional pricing

The curated pricing overlays checked on September 22, 2026 cover:

| Provider | Models | Conditional pricing |
| --- | --- | --- |
| OpenAI | GPT-5.6 (Sol alias), Sol, Terra, Luna; GPT-6 Astra, Sol, Luna | Above 272,000 input tokens, Batch, Flex, Fast/Priority, regional processing |
| Anthropic | Claude Fable 5.1, Opus 5.5, Opus 5, Sonnet 5 | 5m/1h cache writes, Batch, US-only inference |
| Anthropic | Claude Opus 5.5, Opus 5 | Fast mode in addition to the conditions above |
| Anthropic | Claude Haiku 4.5 | 5m/1h cache writes and Batch |
| Google | Gemini 3.1 Pro Preview, including Customtools | Above 200,000 prompt tokens, Batch/Flex, Priority, explicit cache storage |
| xAI | API models with a published long-context threshold, including Grok 4.3, 4.6, 4.7 | At or above 200,000 prompt tokens; selected models have Priority, Batch, US endpoint modifiers |
| Alibaba | Qwen3.7-Plus, Qwen3.6-Plus | Above 256,000 input tokens; Singapore International list prices, explicit/implicit cache distinctions |
| Alibaba | Qwen3.6-Max-preview | Above 128,000 input tokens; Singapore International list prices and explicit cache |
| Moonshot AI | Kimi K3 | 5m/1h cache writes and separate cache reads |

These are first-party prices. Cloud partner and gateway catalogs have independent
pricing. The evidence links and verification date are stored under each model's
`extra.pricing`. Sources: [OpenAI pricing](https://developers.openai.com/api/docs/pricing),
[Claude pricing](https://platform.claude.com/docs/en/about-claude/pricing), and
[Claude prompt caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching).
Other provider references: [Gemini pricing](https://ai.google.dev/gemini-api/docs/pricing),
[xAI pricing](https://docs.x.ai/developers/pricing),
[Alibaba pricing](https://www.alibabacloud.com/help/en/model-studio/model-pricing),
[Alibaba caching](https://www.alibabacloud.com/help/en/model-studio/context-cache), and
[Kimi caching](https://platform.kimi.ai/docs/guide/use-context-caching-feature-of-kimi-api).

#### OpenAI context and processing tiers

```elixir
{:ok, model} = LLMDB.model("openai:gpt-6-sol")

selection = LLMDB.Pricing.components_for(model,
  input_tokens: 272_001,
  api: "responses",
  service_tier: "flex",
  regional_processing: false
)
```

For this context, the selected token rates are the long-context Standard rates:
input $4, output $15, cache read $0.40, and cache write $5 per million tokens.
The selected `pricing.flex` component multiplies each by 0.5. Exactly 272,000
input tokens selects the short tier; 272,001 selects the long tier for **all**
tokens in the request, including output, rather than just the excess tokens.
`input_tokens` here means the total prompt length, including cached tokens; the
billing meters separately count uncached input, cache reads, and cache writes.

Use `api: "batch"` for Batch jobs. For synchronous requests, supply the actual
response `service_tier` (`"default"`, `"flex"`, `"fast"`, or the `"priority"`
alias), accounting for any provider fallback. `"auto"` is a request preference,
not evidence of the tier that was billed. Batch excludes synchronous processing
modifiers so it cannot also receive a Flex discount or Fast premium.

`regional_processing` is a caller-supplied boolean indicating use of a regional
processing endpoint; it is not an OpenAI request parameter. The 1.1 multiplier
stacks with processing and context tiers. Pricing selection does not validate
endpoint eligibility: GPT-6 Sol and Luna allow EU residency only with Standard
processing; Astra Fast mode is unavailable with EU residency. These restrictions
are also recorded in `extra.pricing`.

GPT-5.6 uses the same context boundary and processing multipliers, with its own
base rates. Its Sol rates are promotional, available at least through November
21, 2026; that date is not a confirmed expiry. The `gpt-5.6` alias currently
resolves to Sol. Recheck the resolved model and current provider prices when
refreshing a long-lived estimate.

Reasoning effort changes usage, not the per-token rate. Count billed reasoning
tokens within output usage, rather than charging for them a second time.

#### Claude cache duration and modifiers

```elixir
{:ok, model} = LLMDB.model("anthropic:claude-fable-5-1")

selection = LLMDB.Pricing.components_for(model,
  api: "batch",
  cache_ttl: "1h",
  inference_geo: "us"
)
```

The one-hour cache-write component derives its rate from `token.input` with a
2.0 multiplier. Batch contributes a 0.5 modifier and US-only inference contributes
1.1, so the cache-write rate is `10 * 2 * 0.5 * 1.1 = $11 / MTok`.
`inference_geo: "global"` has no residency premium. Cache reads retain each
model's documented rate: Fable 5.1 and Opus 5.5 have different read discounts.
Haiku 4.5 does not support first-party inference geography.

For synchronous Opus 5.5 or Opus 5, also supply
`request_body: %{speed: "standard"}` or `%{speed: "fast"}`. Fast contributes a
2.0 modifier to token rates, including cache rates, and is unavailable with
Batch. These current Claude models have no long-context premium.

`cache_ttl` selects the rate for a cache-write usage group, not a property of all
tokens in a request. When a response reports both 5m and 1h writes, select each
TTL separately and apply its rate only to that duration's reported token count.
Count input, output, and cache reads once. An omitted or `nil` TTL leaves both
cache-write variants unresolved; it does not assume the cheaper duration.

#### Other provider contexts

For Gemini 3.1 Pro, supply `api: "generate_content"` (or `"batch"`),
`service_tier: "standard"` (or `"flex"`/`"priority"`), and
`cache_type: "implicit"` (or `"explicit"`). Batch and Flex halve input/output
rates but leave cache-read rates unchanged. Priority multiplies token rates and
explicit storage by 1.8. Explicit storage uses `cache_storage_token_hours`,
priced separately from the cached tokens read by each request. Count thinking
tokens as output. These are Gemini API prices, not Vertex AI prices.

For xAI, supply the confirmed `service_tier`, `api`, and normalized `base_url`.
Grok 4.6/4.7 apply the US uplift only for `"https://us.api.x.ai/v1"`.
Grok 4.3 has a 20% Batch discount; this is not a provider-wide discount. The
source mapper preserves API rate values and makes the short/long bands mutually
exclusive. At exactly 200,000 input tokens, Grok selects the **long** band;
Gemini still selects its **short** band.

For the curated Qwen models, supply `region: "singapore"`,
`deployment: "international"`, `api: "chat"`, and `cache_mode: "explicit"`.
Qwen3.7-Plus also has an `"implicit"` cache-read rate; the other two overlays
only assert explicit-cache support. Rates are public list prices, excluding
temporary promotions. These are not prices for other Alibaba regions or
deployments. Missing scope stays unresolved, and an unsupported scope or input
above the documented maximum has no selected rate. Neither outcome is free
usage. Batch excludes the documented cache discounts; it does not establish a
complete Batch tariff.

For Kimi K3, select cache writes with `cache_ttl: "5m"` or `"1h"`. Keep
uncached input, cache reads, and cache writes as disjoint usage categories.
Use the effective billed TTL: an existing cached prefix keeps its original TTL
until expiry. Chat Completions and Responses write implicitly by default;
Messages requires top-level cache configuration to write.
The overlay does not infer a context-price cliff from the model's context limit.

### Using selected components in a billing consumer

`components_for/2` selects metadata; it does not produce final rates or validate
all provider request combinations. For the curated overlays above:

1. Supply known request/response context, including explicit defaults. Missing
   or `nil` values remain unknown. Inspect `selection.unresolved` before pricing
   a usage meter; a missing price or unresolved modifier is not zero cost.
2. Identify each token meter's selected rate. Mutually exclusive context/TTL
   conditions select one rate per meter. Arbitrary custom metadata can still
   contain overlapping rates; the helper does not choose a winner for them.
3. Resolve `derives_from` against the selected base component **before** applying
   token-wide modifiers. Then apply each matching modifier once to each resolved
   rate. Do not apply residency or Batch again through a derived dependency.
4. Match `applies_to` as exact IDs, or as a dotted prefix for patterns ending in
   `.*`. `"token.*"` does not include provider tool or storage fees.
5. Multiply the disjoint measured usage by `rate / per`. Input/cache accounting
   differs across providers; normalize provider usage before calculating cost.
   Preserve `charge_scope` when interpreting tiers. Apply appropriate currency
   precision and rounding in your billing system.

The flat `cost` map remains Standard/default pricing. Existing consumers can
continue reading it, but it cannot estimate a conditional request accurately.
Astra's legacy `extra.pricing.mode_multipliers` is retained for compatibility;
consumers using the canonical modifier components must not apply that legacy
map again. Fable 5.1's former input/output-only Batch variants are replaced by a
single token-wide modifier so cache usage receives the discount too.

### Building context-price bands for preflight decisions

A consumer can use these components to compare projected request costs before
and after reducing a prompt. Build a curve only for a resolved provider/model
and a fixed, supported mode, region, and cache policy. Keep source URLs and the
verification date with that curve so it can be refreshed. Do not substitute a
first-party tariff for a gateway route merely because the model name matches.

For each input-token interval, require one applicable input rate and one output
rate, plus every cache meter the consumer actually uses. Resolve supported
modifiers and derived rates as described above. Require matching currency,
denominators, and `charge_scope: "full_request"`; marginal tiers need different
arithmetic. Require numeric rates; a missing rate is not zero. Reject gaps,
overlaps, relevant unresolved conditions, and modifiers
or usage meters the consumer cannot evaluate. An empty `unresolved` list alone
does not prove that a tariff is complete or a request mode is supported.

If an adapter represents bands with inclusive `up_to` limits, preserve the
provider's exact boundary: Gemini's first band ends at `200_000`, while Grok's
ends at `199_999`. Qwen uses decimal thousands. Never guess a billing boundary
from `limits.context` or the model name, and do not extend a finite published
band to infinity.

Use **total prompt tokens, including cached content**, to select a context
band. Use separate billable token counts to calculate its cost. The output
rate is selected by input length too; a large output does not itself move the
request into a more expensive input band. Cache hits reduce the billable input
cost but do not remove cached tokens from the context threshold.

A price-aware compaction decision should compare the complete projected request
in the higher band with the expected reduced request in the lower band,
including expected output and cache usage. Savings must exceed the separately
priced summarization request. An input/output/cache-read-only curve cannot
price explicit cache creation or retained cache storage; extend the evaluator
or decline that estimate. A flat-rate model can still save tokens, but does not
provide evidence of a context-price cliff.

## Migration from Legacy Cost Format

The legacy `cost` field is automatically converted to `pricing.components` at load time by `LLMDB.Pricing.apply_cost_components/1`.

### Mapping

| Legacy Field | Component ID | Kind | Unit | Per |
|--------------|--------------|------|------|-----|
| `cost.input` | `token.input` | token | token | 1,000,000 |
| `cost.output` | `token.output` | token | token | 1,000,000 |
| `cost.cache_read` | `token.cache_read` | token | token | 1,000,000 |
| `cost.cache_write` | `token.cache_write` | token | token | 1,000,000 |
| `cost.reasoning` | `token.reasoning` | token | token | 1,000,000 |

### Example Conversion

```elixir
# Legacy format (in TOML or input data)
%{
  cost: %{input: 3.0, output: 15.0, cache_read: 0.3}
}

# Automatically becomes
%{
  cost: %{input: 3.0, output: 15.0, cache_read: 0.3},
  pricing: %{
    currency: "USD",
    components: [
      %{id: "token.input", kind: "token", unit: "token", per: 1_000_000, rate: 3.0},
      %{id: "token.output", kind: "token", unit: "token", per: 1_000_000, rate: 15.0},
      %{id: "token.cache_read", kind: "token", unit: "token", per: 1_000_000, rate: 0.3}
    ]
  }
}
```

The legacy `cost` field remains available for backward compatibility with existing code.

## Custom Providers with Pricing

When defining custom providers at runtime, you can include `pricing_defaults`:

```elixir
{:ok, _} = LLMDB.load(
  custom: %{
    my_provider: [
      name: "My Provider",
      base_url: "https://api.example.com/v1",
      pricing_defaults: %{
        currency: "USD",
        components: [
          %{id: "tool.custom_search", kind: "tool", tool: "custom_search", unit: "call", per: 1000, rate: 5.0},
          %{id: "storage.vectors", kind: "storage", unit: "gb_day", per: 1, rate: 0.05}
        ]
      },
      models: %{
        "my-model" => %{
          name: "My Model",
          capabilities: %{chat: true, tools: %{enabled: true}},
          cost: %{input: 1.0, output: 2.0}
        }
      }
    ]
  }
)

# The model inherits provider pricing_defaults
{:ok, model} = LLMDB.model("my_provider:my-model")
model.pricing.components
# => [
#   %{id: "token.input", ...},
#   %{id: "token.output", ...},
#   %{id: "tool.custom_search", ...},
#   %{id: "storage.vectors", ...}
# ]
```

### Model-Level Pricing Overrides

```elixir
{:ok, _} = LLMDB.load(
  custom: %{
    my_provider: [
      name: "My Provider",
      pricing_defaults: %{
        currency: "USD",
        components: [
          %{id: "tool.search", kind: "tool", tool: "search", unit: "call", per: 1000, rate: 10.0}
        ]
      },
      models: %{
        "basic-model" => %{
          capabilities: %{chat: true},
          cost: %{input: 1.0, output: 2.0}
          # Inherits tool.search at $10/1000
        },
        "premium-model" => %{
          capabilities: %{chat: true},
          cost: %{input: 5.0, output: 15.0},
          pricing: %{
            merge: "merge_by_id",
            components: [
              # Free search for premium tier
              %{id: "tool.search", kind: "tool", tool: "search", unit: "call", per: 1000, rate: 0.0}
            ]
          }
        }
      }
    ]
  }
)
```

## Next Steps

- **[Schema System](schema-system.md)**: Full schema definitions including pricing
- **[Model Struct Evolution Proposal](model-struct-evolution-proposal.md)**: Conditional pricing design and implementation status
- **[Using the Data](using-the-data.md)**: Runtime API and queries
