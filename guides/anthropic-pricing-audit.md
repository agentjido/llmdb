# Anthropic pricing audit

Checked 2026-10-09 against the first-party [pricing table](https://platform.claude.com/docs/en/about-claude/pricing), [prompt caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching), and [model deprecations](https://platform.claude.com/docs/en/about-claude/model-deprecations).

This audit covers all 20 canonical models in the packaged `anthropic` provider. Aliases resolve to these definitions. Partner providers have their own price lists.

All 17 models with documented token prices now declare five-minute and one-hour cache-write rates and a Batch discount. Retired models that already had no token prices remain unpriced. Retired Opus 4, Opus 4.1, and Sonnet 4 retain their documented historical rates.

| Model | Input | Output | Cache read | Five-minute write | One-hour write | Additional rules |
|---|---:|---:|---:|---:|---:|---|
| `claude-3-5-haiku-20241022` | — | — | — | — | — | Retired; no token prices |
| `claude-3-7-sonnet-20250219` | — | — | — | — | — | Retired; no token prices |
| `claude-3-haiku-20240307` | — | — | — | — | — | Retired; no token prices |
| `claude-fable-5` | 10 | 50 | 1 | 12.5 | 20 | Batch 0.5x; US-only 1.1x |
| `claude-fable-5-1` | 10 | 50 | 0.25 | 12.5 | 20 | Batch 0.5x; US-only 1.1x |
| `claude-haiku-4-5-20251001` | 1 | 5 | 0.1 | 1.25 | 2 | Batch 0.5x |
| `claude-haiku-5-5` | 0.1 | 0.5 | 0.01 | 0.125 | 0.2 | Batch 0.5x; US-only 1.1x; Full prompt above 100K: 5x |
| `claude-opus-4-1-20250805` | 15 | 75 | 1.5 | 18.75 | 30 | Batch 0.5x; Historical; retired on Claude API |
| `claude-opus-4-20250514` | 15 | 75 | 1.5 | 18.75 | 30 | Batch 0.5x; Historical; retired on Claude API |
| `claude-opus-4-5-20251101` | 5 | 25 | 0.5 | 6.25 | 10 | Batch 0.5x |
| `claude-opus-4-6` | 5 | 25 | 0.5 | 6.25 | 10 | Batch 0.5x; US-only 1.1x |
| `claude-opus-4-7` | 5 | 25 | 0.5 | 6.25 | 10 | Batch 0.5x; US-only 1.1x |
| `claude-opus-4-8` | 5 | 25 | 0.5 | 6.25 | 10 | Batch 0.5x; US-only 1.1x; Fast 2x; excluded for Batch |
| `claude-opus-5` | 5 | 25 | 0.5 | 6.25 | 10 | Batch 0.5x; US-only 1.1x; Fast 2x; excluded for Batch |
| `claude-opus-5-5` | 4 | 20 | 0.2 | 5 | 8 | Batch 0.5x; US-only 1.1x; Fast 2x; excluded for Batch |
| `claude-sonnet-4-20250514` | 3 | 15 | 0.3 | 3.75 | 6 | Batch 0.5x; Historical; retired on Claude API |
| `claude-sonnet-4-5-20250929` | 3 | 15 | 0.3 | 3.75 | 6 | Batch 0.5x |
| `claude-sonnet-4-6` | 3 | 15 | 0.3 | 3.75 | 6 | Batch 0.5x; US-only 1.1x |
| `claude-sonnet-5` | 2 | 10 | 0.2 | 2.5 | 4 | Batch 0.5x; US-only 1.1x |
| `claude-sonnet-5-5` | 2 | 10 | 0.1 | 2.5 | 4 | Batch 0.5x; US-only 1.1x |

All token rates in this table are USD per million tokens at the base prompt band.

## Corrections

- Sonnet 5.5 now has its USD 4 one-hour write rule and its model-specific USD 0.10 cache-read rate. This addresses issue [#346](https://github.com/agentjido/llmdb/issues/346).
- Haiku 5.5 now has its USD 0.20 one-hour write rule. All token categories receive a 5x modifier when the full prompt exceeds 100,000 tokens. Prompt length includes uncached input, cache reads, and cache writes.
- Fable 5, Opus 4.5 through 4.8, Sonnet 4.5/4.6, and the retained Opus 4/4.1 and Sonnet 4 records no longer depend on an unconditional legacy cache-write component.
- Opus 4.8 now has its documented fast-mode multiplier. Opus 4.6 and 4.7 do not acquire that surcharge.
- Residency rules apply to Claude 4.6 and later and Fable models. Earlier models do not acquire a residency premium.
- Sonnet 4.5 is deprecated from September 30, 2026 and retires November 30, 2026. Opus 4/4.1 and Sonnet 4 have their documented retired status.

The five-minute rule reuses `token.cache_write` to replace the legacy component by ID. The one-hour rule derives from the base input rate at 2x. Token-wide modifiers apply once after derivation. An absent or unsupported TTL cannot fall back to a generic write rate.

## Validation and release

`test/llm_db/anthropic_pricing_coverage_test.exs` checks all packaged Anthropic models, both TTLs, Batch and residency combinations, fast-mode support, the exact Haiku 5.5 boundary, missing contexts, legacy conversion, and retirement records. The packaged snapshot is rebuilt and checked into this PR, so the next Hex package contains the corrected data.

The two saved ReqLLM Haiku 5.5 mixed-TTL captures replayed at USD 0.010739 in both response modes with this rebuilt snapshot. That matches their independent calculation. No new provider calls were made. Original captures and observed charges were retained.

After this PR merges, run the normal release workflow from current main. Release CI selects the version and validates the snapshot, tests, quality checks, and package before publication. This PR does not publish a package or change the version by hand.
