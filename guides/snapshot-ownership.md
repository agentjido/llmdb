# Snapshot Ownership and Integration

## Decision

LLMDB keeps `priv/llm_db/snapshot.json` as the compact, tracked catalog used by
ordinary runtime loading, compile-time embedding, Hex packaging, NPM export,
and immutable snapshot publication. Catalog pull requests change the mergeable
inputs, tests, and build code; they do not change the assembled snapshot. A
serialized `main` workflow owns regeneration from the integrated source state.

This is the tracked-baseline alternative from issue #380. It is the smallest
migration that removes the generated-file conflict from independent catalog
pull requests without changing the snapshot schema, public API, package
contents, or offline behavior.

The alternatives were not selected yet:

- Pretty-printing the snapshot would improve review locality, but every build
  would still change the shared `snapshot_id` and `generated_at` fields. It
  would also undo the measured compact-package savings.
- Untracking the assembled snapshot would require a new pre-compilation
  bootstrap and a different Hex/Git/path dependency contract. That remains a
  possible later phase only after that contract is independently proven.

## Source of truth and ownership

The versioned inputs are the source of truth for the next catalog:

- local provider and model TOML under `priv/llm_db/local/`;
- pinned upstream and remote cache files under `priv/llm_db/upstream/` and
  `priv/llm_db/remote/`;
- the exact checked-out build code, configuration, and `mix.lock`.

`priv/llm_db/snapshot.json` is a generated, reviewed distribution baseline.
Only the `Integrate Catalog Snapshot` workflow and the scheduled metadata
publisher use `mix llm_db.build --install-source` and commit the result to
`main`. Contributor pull requests must not edit it.

The integration workflow is serialized with scheduled metadata publication.
It checks out the latest `main`, builds from that exact tree, strictly verifies
the installed document, runs catalog tests and quality checks, and commits only
the compact snapshot. A rejected push is rebased onto the newer `main`, rebuilt,
and revalidated, so a concurrent input merge is included rather than silently
discarded. The resulting immutable snapshot and history checkpoint are then
published through the existing content-addressed store.

This leaves one intentional limitation: a just-merged input commit can be
followed briefly by the prior tracked baseline while the serialized integration
workflow runs. Pull-request CI tests the effective generated catalog before the
merge, and releases require the committed snapshot to match the tagged inputs.
A failed integration workflow is therefore visible and blocks release; it does
not fall back to an unrelated `latest` artifact.

## Bootstrap and consumer boundary

The tracked snapshot remains present before Elixir compilation. That preserves
the existing order for a fresh clone and for Git, path, and Hex dependencies:

1. dependency files are installed from the lock or package manifest;
2. the trusted packaged snapshot compiles the bounded provider registry;
3. `LLMDB.Packaged` either records the snapshot as an external resource or
   embeds it when `compile_embed: true`;
4. the first catalog query verifies and loads that same snapshot without a
   provider network request or credentials.

Provider registry compilation now fails if the trusted snapshot is absent,
malformed, has an unsafe provider ID, or exceeds the provider limit. Runtime
JSON still cannot create provider atoms. In pull-request CI, the effective
snapshot is installed before the final compile/test pass, so a newly added
provider reaches the final compiled registry.

Hex continues to contain compact `priv/llm_db/snapshot.json`. The NPM exporter
continues to derive deterministic provider shards and its manifest from that
same strict snapshot. Both therefore carry the same semantic `snapshot_id` for
a release. No consumer compilation or query downloads an artifact, resolves a
floating `latest`, or contacts provider APIs.

## Reproducibility and time

`snapshot_id` is computed from normalized catalog content and excludes capture
and publication timestamps. The same checked-out inputs and locked
dependencies therefore produce the same semantic identity even if builds run
at different times. `generated_at`, `captured_at`, and `published_at` describe
observations and publication events; byte-for-byte equality across different
wall-clock times is not promised. JSON encoding remains deterministic and
compact once the document is fixed.

Publication records the Git commit containing the integrated inputs and
snapshot as `source_commit`. Existing history is not rewritten. Immutable
snapshot releases, parent identities, and incremental history checkpoints
continue through the existing publication tasks. Publication fails if catalog
source paths differ from `HEAD`, preventing a dirty worktree from being
attributed to the wrong commit.

## Contributor migration

For a catalog change:

1. Update only the appropriate TOML or pinned cache input and its focused test.
2. Run `mix catalog.verify` to build the effective catalog twice and verify the
   semantic output without modifying the tracked snapshot.
3. Run `mix test` and `mix quality`.
4. Confirm `git diff -- priv/llm_db/snapshot.json` is empty before opening the
   pull request.
5. After merge, watch `Integrate Catalog Snapshot`; it commits and publishes the
   integrated compact snapshot.

Maintainers can still run `mix llm_db.build` for local inspection. The result
stays under `_build`.
Scheduled refreshes still commit changed upstream/remote inputs together with
the snapshot because that serialized workflow owns both.

## Independent-change integration evidence

`LLMDB.SnapshotIntegrationTest` supplies two independent provider/model input
layers, builds only from their combined source state, and asserts that both
survive in one strict snapshot. Reversing the two disjoint input layers yields
the same semantic identity. CI also rejects a pull request that changes the
generated snapshot, so the two contributing branches have no shared generated
line to resolve manually.

This decision does not solve conflicts inside an input cache. Two changes to
the same upstream or remote JSON file may still require a source-aware merge or
a fresh pull. Input-cache conflict work remains separate from snapshot
ownership.
