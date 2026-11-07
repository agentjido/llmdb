# LLM Metadata Audit Checklist

## Evidence Rules

- Use official provider sources as authority. Treat third-party aggregators, blog posts, archived pages, and model marketplace mirrors as leads only.
- Prefer machine-readable public model data when it is official and unauthenticated.
- Do not infer undocumented limits, prices, capabilities, or lifecycle status from marketing language alone.
- If provider docs omit a field, mark the local value `unverified` unless another official source confirms it.
- If docs and API disagree, report both with dates and prefer the source that is more specific to the field under review.

## Local Artifacts

- Configured source order is remote/aggregate sources first and `LLMDB.Sources.Local` last; local TOML is highest precedence.
- Raw provider API cache lives under `priv/llm_db/remote/`. It is pulled by source modules such as `LLMDB.Sources.Anthropic`; do not hand-edit it.
- Aggregate upstream cache lives under `priv/llm_db/upstream/`; do not hand-edit it.
- Curated local overlays live in `priv/llm_db/local/<provider_id>/provider.toml` and one TOML file per model.
- Generated provider registry files live in `priv/llm_db/providers/<provider_id>.json`; do not hand-edit them.
- Built metadata lives in `priv/llm_db/snapshot.json` under `providers.<provider_id>.models`; do not hand-edit it.
- Source transforms live in `lib/llm_db/sources/`. Enrichment/runtime derivations live in `lib/llm_db/engine/` and `lib/llm_db/enrich/`.

## Comparison Method

1. Build a model inventory from local metadata and from public docs/API evidence.
2. Classify each local model:
   - `verified`: official source confirms the model or alias and no checked fields conflict.
   - `mismatch`: official source contradicts a local value.
   - `missing-upstream`: official source lists the model but local metadata lacks it.
   - `stale-local`: local metadata lists a model official docs say is removed, retired, or unavailable.
   - `unverified`: official public sources do not expose enough information.
3. Compare high-impact fields first: model ID, `provider_model_id`, endpoint/path, lifecycle, pricing, context/output limits.
4. Compare secondary fields after that: modalities, capabilities, release/update dates, knowledge cutoff, docs URL, names, tags, notes.
5. Normalize before judging:
   - Convert prices to comparable units and note whether rates are per token, per 1K tokens, per 1M tokens, per request, per image, per second, or per tool call.
   - Convert context windows expressed in K/M tokens to integers.
   - Preserve exact provider model IDs, including case, slashes, colons, date suffixes, and preview labels.
   - Treat aliases and versioned IDs as different unless official docs explicitly define the alias.

## Capture Layer Decision Rules

Every finding must recommend where to capture the learning:

| Evidence and problem | Capture layer | Action |
| --- | --- | --- |
| Provider API cache is stale or absent | `remote-cache` | Run `mix llm_db.pull --source <provider_id>` if credentials are available; commit the refreshed cache if changed. |
| Provider API returns the fact but final metadata is missing or wrong | `source-transform` | Fix `lib/llm_db/sources/<provider>.ex`, add/update tests, rebuild artifacts. |
| Provider API omits the fact but official docs publish it | `local-override` | Add the smallest TOML overlay under `priv/llm_db/local/<provider>/`; do not duplicate API-returned fields unnecessarily. |
| Official docs identify a model alias, lifecycle state, pricing table, or deprecation schedule absent from the API | `local-override` | Capture the durable curated fact in TOML, with sparse fields only. |
| A rule applies across many models or providers | `enrichment` | Update enrichment/runtime code instead of copying overrides into many TOMLs. |
| A generated file is stale after source changes | `generated-artifact` | Run `mix catalog.verify`; commit the source inputs and tests. |
| Evidence is contradictory or unavailable | `unverified` | Do not edit. Report the ambiguity and exact sources checked. |

For endpoint-backed sources, separate "endpoint truth" from "docs-only truth." A model endpoint often supplies inventory, display names, creation timestamps, limits, and capabilities, while separate docs may be the only source for lifecycle, aliases, pricing, migration guidance, and feature caveats.

## Report Template

```markdown
Provider: <provider_id> | Result: <verified|mismatches found|incomplete evidence>

Sources checked on <YYYY-MM-DD>:
- <official source title>: <url>

Summary:
- Checked: <n> models / <n> provider fields
- Verified: <n>
- Mismatched: <n>
- Unverified: <n>

Findings:
- [P1] <field/model>: <local value> vs <official evidence>. Capture layer: <layer>. File/action: <path or command>. Source: <url>

Changes:
- <path>: <specific edit>

Verification:
- <command>: <result>

PR:
- Branch: <branch>
- Commit: <sha or message>
- URL: <pull request URL>

Unverified:
- <field/model>: <why public evidence was insufficient>
```

## Severity

- `P1`: A consumer could call the wrong model, endpoint, price, or lifecycle state.
- `P2`: A consumer could make a poor routing or capability decision because limits, modalities, or capability metadata is wrong.
- `P3`: Metadata quality issues such as stale names, docs URLs, dates, tags, or missing noncritical notes.

## PR Readiness

- Verify with `mix catalog.verify` after source-layer edits.
- Run `mix test` for source transform, merge, enrichment, or generated artifact changes. Use targeted tests only when the change is tightly scoped and call out why broader tests were skipped.
- Do not include generated provider JSON or `priv/llm_db/snapshot.json` in a catalog pull request.
- Commit with a Conventional Commit message, for example `fix: update anthropic model lifecycle metadata`.
- Open a PR that lists official evidence, changed capture layers, tests run, and remaining unverified fields.
