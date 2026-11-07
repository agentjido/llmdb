---
name: verify-llm-metadata
description: Verify and update one LLM provider's llm_db metadata against that provider's public documentation, public model API data, and cached upstream source data, then prepare a PR. Use when asked to audit, check, confirm, validate, fix, or update provider model metadata such as model IDs, endpoints, limits, prices, modalities, capabilities, lifecycle/deprecation status, aliases, release dates, source mappings, or provider docs for this repository.
---

# Verify LLM Metadata

## Scope

Verify exactly one provider per run. If the request names zero providers or multiple providers, ask the user for one provider ID before continuing.

Use public provider documentation and public model data only. Do not use private dashboards, paid accounts, leaked docs, or secrets. If an API requires authentication and no user-approved credential is already in scope, use the provider's public docs instead and mark API-backed evidence unavailable.

The normal end state is a pull request containing source-layer changes plus regenerated artifacts. If the user explicitly asks for audit-only output, stop after the report.

## Batch Orchestration

Do not ask one agent invocation to verify multiple providers. To audit a queue, run one isolated invocation of this skill per provider.

Use `references/provider-sets.json` for curated provider queues. The default `popular_core` set covers the highest-priority popular providers already present in this repo; `popular_extended` broadens coverage to more widely used labs, routers, and inference platforms.

Preview the batch commands:

```bash
python3 .agents/skills/verify-llm-metadata/scripts/provider_verification_loop.py --provider-set popular_core
```

Execute the batch with one Codex invocation per provider, each in its own worktree:

```bash
python3 .agents/skills/verify-llm-metadata/scripts/provider_verification_loop.py --provider-set popular_core --execute
```

Use `--mode audit-only` for reports without edits or PRs. Use `--provider-set popular_extended`, `--providers <id> ...`, `--start-at <id>`, or `--limit <n>` to control the queue.

## Workflow

1. Identify the provider ID used by this repo, such as `openai`, `anthropic`, `google`, `xai`, `azure`, or another folder/key under `priv/llm_db/local` or `priv/llm_db/snapshot.json`.
2. Create or switch to a focused branch unless the user asked for audit-only work.
3. Extract the provider metadata stack:

   ```bash
   python3 .agents/skills/verify-llm-metadata/scripts/extract_provider_metadata.py <provider_id> --repo-root .
   ```

   Save large output under `tmp/` if needed:

   ```bash
   python3 .agents/skills/verify-llm-metadata/scripts/extract_provider_metadata.py <provider_id> --repo-root . --out tmp/<provider_id>-metadata.json
   ```

   The helper extracts the built snapshot, generated provider registry, local TOML overlays, and raw remote cache when present. On Python versions without TOML support, source TOML entries may contain `_parse_error`; use the emitted file paths with `sed`/`rg` for source-level inspection.

4. Read `references/audit-checklist.md` before comparing fields or editing files.
5. Inspect the source stack for this provider:
   - configured source module, such as `lib/llm_db/sources/<provider>.ex`
   - raw remote cache under `priv/llm_db/remote/`
   - local overrides under `priv/llm_db/local/<provider>/`
   - generated outputs under `priv/llm_db/providers/` and `priv/llm_db/snapshot.json`
6. If credentials are already available and the user has not forbidden network/API calls, refresh the provider source:

   ```bash
   mix llm_db.pull --source <provider_id>
   ```

   If the pull is skipped because no key is available, continue with existing cache plus public docs.
7. Search the web for the provider's official public model source. Start from the local provider `doc` URL when present, then search official domains for:
   - model list or model catalog
   - API reference for list-models/model endpoints
   - pricing page
   - deprecation, lifecycle, changelog, release notes, or model migration pages
8. Prefer evidence in this order:
   - Official public model endpoint or machine-readable model catalog from the provider
   - Official provider API reference or docs page
   - Official pricing, deprecation, changelog, or release note page
   - Official SDK examples only when they identify model IDs or endpoints
   - Third-party catalogs only as search leads, not as authority
9. Compare public evidence to local metadata. Treat missing provider docs as `unverified`, not necessarily wrong. Normalize units before calling a mismatch:
   - context/output limits: tokens unless docs state otherwise
   - prices: convert to the repo's per-million-token or component pricing conventions
   - dates: ISO dates when possible
   - aliases: distinguish documented aliases from concrete versioned model IDs
   - endpoints: distinguish provider base URL from operation paths and wire protocol
10. For every finding, choose the recommended capture layer before editing. Do not default to local TOML just because it has highest precedence.
11. Implement changes in source files only. Do not hand-edit generated `priv/llm_db/providers/*.json` or `priv/llm_db/snapshot.json`.
12. Rebuild and verify:

    ```bash
    mix catalog.verify
    mix test
    ```

    Use a targeted test first if the change is narrow, then run broader checks when source transforms, merge behavior, or generated artifacts changed.
13. Commit with a Conventional Commit message and open a pull request. Include evidence links and a short source-layer rationale in the PR body.

## Layer Placement

Each finding must include a `capture layer`:

- `remote-cache`: Re-run `mix llm_db.pull --source <provider_id>` when the raw provider API cache is stale or absent. Never hand-edit remote cache files.
- `source-transform`: Edit `lib/llm_db/sources/<provider>.ex` when the official API returns a field but the repo drops, misnames, or mis-maps it.
- `local-override`: Edit sparse TOML under `priv/llm_db/local/<provider>/` for curated facts absent from the API but present in official docs, such as lifecycle/deprecation, aliases, pricing pages, and documented provider exclusions.
- `enrichment`: Edit enrichment/runtime code when the same derived rule applies across many models/providers.
- `generated-artifact`: Verify with `mix catalog.verify`; commit the source inputs and tests.
- `unverified`: Do not edit; document what evidence is missing.

For providers backed by a model endpoint, remember that the endpoint may not include docs-only fields. For example, Anthropic's Models API exposes IDs, display names, creation dates, capabilities, and token limits, but lifecycle/deprecation, pricing, aliases, and some docs context can require separate public documentation.

## Verify Fields

Check these fields when the provider publishes them:

- Provider metadata: `name`, `doc`, `base_url`, environment variable hints, runtime/endpoint notes.
- Model inventory: local model IDs, documented model IDs, removed or missing models, aliases, `provider_model_id`.
- Dates and lifecycle: `release_date`, `last_updated`, `knowledge`, `deprecated`, `retired`, `lifecycle`.
- Limits: `limits.context`, `limits.output`, embedding dimensions, image/audio constraints when modeled.
- Pricing: `cost`, `pricing.components`, currency, per-unit basis, cache/read/write/tool/storage meters.
- Capabilities: chat/text, embeddings, rerank, image, audio, realtime, reasoning, tool calling, JSON/schema support, streaming, caching.
- Modalities: text, image, audio, pdf, video input/output.
- Execution metadata: base URL overrides, path, operation family, transport, and wire protocol.

## Output

Start with a concise status line:

`Provider: <provider_id> | Result: verified / mismatches found / incomplete evidence`

Then include:

- Sources: official URLs used, with access date.
- Summary counts: checked, verified, mismatched, unverified.
- Findings: ordered by severity (`P1` wrong model IDs/endpoints/pricing/lifecycle, `P2` limits/capabilities/modalities, `P3` names/docs/dates/notes), each with `capture layer`, file path, and action.
- Changes made: source files changed, generated artifacts rebuilt, tests run.
- PR: branch, commit, PR URL, and any known residual uncertainty.
- Evidence notes: quote only short excerpts and paraphrase the rest.

Be explicit when evidence is ambiguous. Use phrases such as `not publicly documented`, `docs conflict`, `API requires authentication`, or `provider page does not expose this field`.
