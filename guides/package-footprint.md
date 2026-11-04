# Package Footprint

The packaged catalog uses deterministic compact schema-v1 JSON. This changes
only JSON whitespace: decoded keys, values, array order, schema version, and
snapshot ID remain unchanged.

Catalog pull requests do not regenerate this shared file. A serialized `main`
workflow assembles it from the integrated versioned inputs, preserving the
compact Hex artifact and the canonical source used for NPM provider shards.
See [Snapshot Ownership and Integration](snapshot-ownership.md).

## Size comparison

Measured from the same 2026-07 packaged snapshot and package source tree with:

```shell
wc -c priv/llm_db/snapshot.json
gzip -n -c priv/llm_db/snapshot.json | wc -c
mix hex.build
```

| Artifact | Pretty JSON | Compact package | Change |
| --- | ---: | ---: | ---: |
| Raw `snapshot.json` | 12,198,384 bytes | 6,325,229 bytes | -48.1% |
| Gzip (`gzip -n`) | 582,088 bytes | 455,025 bytes | -21.8% |
| Hex archive | 756,224 bytes | 623,616 bytes | -17.5% |

These measurements are release-audit evidence, not fixed size budgets; catalog
growth will change them.

## Opt-in sparse v2 comparison

The same 168-provider, 5,988-model catalog was encoded with the schema-v2 sparse
rules using `LLMDB.Snapshot.to_sparse/1`. The packaged and published default is
still v1; this comparison records the evidence for the opt-in format.

| Artifact | Compact v1 | Sparse v2 | Change from v1 |
| --- | ---: | ---: | ---: |
| Raw `snapshot.json` | 6,325,229 bytes | 5,264,366 bytes | -16.8% |
| Gzip (`gzip -n`) | 455,025 bytes | 430,800 bytes | -5.3% |

Sparse v2 omits only schema-enumerated provider/model nulls and defaults. See
[Snapshot Formats and Sparse v2 Rollout](snapshot-formats.md) for the exact
rules, integrity behavior, and packaged-default rollout gate.

## Hex package manifest

The package deliberately includes:

- `lib` and `mix.exs` for runtime code and supported Mix tasks;
- `priv/llm_db/snapshot.json` for zero-network catalog use;
- `config` for the repository-maintainer task defaults retained during the
  compatibility window;
- `guides`, `README.md`, and `CHANGELOG.md` for HexDocs and release history;
- `LICENSE` for licensing.

Repository-only contributor instructions (`AGENTS.md`, `usage-rules.md`) and
the repository formatter configuration (`.formatter.exs`) are excluded. No
runtime module, supported task, guide, source configuration, license, or
packaged metadata is removed.
