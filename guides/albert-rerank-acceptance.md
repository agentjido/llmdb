# Albert rerank acceptance before snapshot integration

## Bundled acceptance fork

At the ZAQ consumer's request, this fork's acceptance revision also includes the
generated `priv/llm_db/snapshot.json`, built from the committed inputs with
`mix llm_db.build --install` and verified with `mix llm_db.build --verify`.
Its semantic snapshot ID is
`680924fa27524cc38a372a0f09d1d133649a909fd038eb309815c15ea8225ff7`.
Consumers pinned to that complete revision use normal packaged-catalog loading;
no consumer-side artifact build, environment variable or configuration is needed.

Bundling is an explicit consumer-acceptance exception on this fork, not upstream
approval or a change to the serialized `main` snapshot ownership policy. For an
input-only upstream PR, retain the source/tests and let integration automation
produce the release artifact. The separate-artifact instructions below apply to
those input-only revisions, not the bundled acceptance revision.

The Albert reranker uses `execution.rerank.base_url =
"https://albert.api.etalab.gouv.fr/v1"` and `path = "/rerank"`. Both the
execution default and an explicitly configured Albert provider base URL must
produce `https://albert.api.etalab.gouv.fr/v1/rerank`. Its provider remains
`albert`, and its wire model ID remains `openweight-rerank`.

Albert BGE-M3's `capabilities.embeddings.max_dimensions` is **1024**, not its
8192-token context limit. This is already recorded in the Albert-specific TOML
and confirmed by the [official model reference](https://guides.ia.numerique.gouv.fr/albert-api/modeles/available-models#bge-m3).
No dimension or execution changes to other providers are needed.

## Reproduce an input-only PR in a consumer

Catalog PRs do not commit generated snapshots. Pinning the Git dependency alone
does **not** regenerate the packaged snapshot. Until release automation integrates
the inputs, use an explicit, separate acceptance artifact instead of modifying
`deps/llm_db/priv/llm_db/snapshot.json` or fetching a floating `latest` snapshot.

1. Clone the PR repository into a standalone directory (not inside the consumer's
   `deps/`), check out the exact PR commit, and install its locked dependencies:

   ```sh
   git clone https://github.com/jfayad/llmdb.git llmdb-albert-acceptance
   cd llmdb-albert-acceptance
   git checkout --detach <PR_COMMIT_SHA>
   mix deps.get
   mix llm_db.build --verify --output-dir "$PWD/tmp/albert-acceptance"
   ```

   Run this in the default `dev` environment so the committed upstream caches
   are used, not the test cache directories. No provider API pull, account, or
   secret is required. The build writes `snapshot.json` and
   `snapshot.meta.json` under `tmp/albert-acceptance/`; verification strictly
   reads the artifact and rebuilds it to confirm the same semantic snapshot ID.
   Capture that ID with the exact source SHA. Timestamps may differ on rebuild.

2. Pin the consumer's `llm_db` dependency to the **same exact PR commit**.
   Configure the consumer before compiling/starting LLMDB:

   ```elixir
   config :llm_db,
     compile_embed: false,
     integrity_policy: :strict,
     snapshot_path: Path.expand("/absolute/path/to/llmdb-albert-acceptance/tmp/albert-acceptance/snapshot.json")
   ```

   Make this acceptance configuration reproducible in the consumer's own
   configuration or test tooling; do not patch an untracked dependency file.
   If it previously compiled LLMDB with embedding enabled, recompile that
   dependency with embedding disabled and restart the consumer. The embedded
   mode reads the packaged compile-time file, not this runtime override.

3. Confirm the artifact ID and effective catalog through the public API:

   ```elixir
   {:ok, artifact} = LLMDB.Snapshot.read(LLMDB.Packaged.snapshot_path(), integrity_policy: :strict)
   IO.puts(artifact["snapshot_id"])

   {:ok, reranker} = LLMDB.model(:albert, "bge-reranker-v2-m3")
   true = reranker.execution.rerank.base_url == "https://albert.api.etalab.gouv.fr/v1"
   true = reranker.execution.rerank.path == "/rerank"
   true = reranker.execution.rerank.provider_model_id == "openweight-rerank"

   {:ok, embedding} = LLMDB.model(:albert, "bge-m3")
   true = embedding.capabilities.embeddings.max_dimensions == 1024
   ```

This runtime-file workflow is for local acceptance, not a change to snapshot
ownership. A consumer requiring the corrected snapshot embedded in an unchanged
Git/Hex dependency must wait for the serialized integration/release artifact;
an input-only PR pin cannot provide that guarantee.
