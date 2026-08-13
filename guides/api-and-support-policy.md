# API and Support Policy

LLM DB separates its consumer API from build-time extension points and internal
implementation modules. This boundary lets the catalog evolve without forcing
downstream applications to follow internal refactors.

## Stable Runtime API

The following interfaces are covered by the package's backwards-compatibility
policy:

- The `LLMDB` facade: catalog loading, provider/model lookup, selection,
  capability queries, filtering policy checks, and model-spec utilities.
- `LLMDB.Model` and `LLMDB.Provider` structs, constructors, documented fields,
  and `LLMDB.Model` JSON representation.
- `LLMDB.Spec` parsing and formatting contracts exposed through `LLMDB`.
- `LLMDB.History` read APIs and published history bundle readers.
- Existing snapshot versions accepted by `LLMDB.Snapshot` and `LLMDB.load/1`.

Primary return shapes are:

| Operation | Success | Not found / no match |
| --- | --- | --- |
| `LLMDB.load/0,1` | `{:ok, snapshot}` | `{:error, reason}` |
| `LLMDB.providers/0` | `[%LLMDB.Provider{}]` | `[]` |
| `LLMDB.provider/1` | `{:ok, %LLMDB.Provider{}}` | `{:error, :not_found}` |
| `LLMDB.models/0,1` | `[%LLMDB.Model{}]` | `[]` |
| `LLMDB.model/1,2` | `{:ok, %LLMDB.Model{}}` | `{:error, reason}` |
| `LLMDB.select/0,1` | `{:ok, {provider, model_id}}` | `{:error, :no_match}` |
| `LLMDB.candidates/0,1` | `[{provider, model_id}]` | `[]` |
| `LLMDB.allowed?/1` | boolean | `false` |
| `LLMDB.capabilities/1` | capability map | `nil` |

Minor releases may add fields or accepted inputs and may correct behavior that
contradicts documented contracts. They do not remove accepted inputs, struct
fields, snapshot readers, or supported task names without a deprecation window.

Runtime catalog loading reads a packaged or explicitly configured snapshot. It
does not pull upstream provider metadata, read a host `.env`, or own application
environment setup. The maintainer-only `mix llm_db.pull` task is the sole
automatic dotenv boundary.

The catalog initializes on the first public query without an llm_db supervisor
or worker. Strict integrity errors therefore surface as `LLMDB.LoadError` at
first use; explicit `LLMDB.load/1` calls retain their `{:error, reason}` shape
and can preload the catalog during consumer application startup. The
`LLMDB.Application` callback is a deprecated compatibility shim for one minor
release and is no longer registered as the package's OTP callback.

## Supported Artifacts and Extensions

- `LLMDB.Source` is the supported build-time source behaviour. Its canonical
  output shape and optional `pull/1` callback are extension contracts.
- `LLMDB.Snapshot` defines the supported snapshot artifact and reader. Existing
  schema versions remain readable when a new version is introduced.
- Documented `mix llm_db.*` tasks are supported maintainer entry points.

Direct calls into Engine stages, source adapter internals, snapshot publishing
helpers, or history rebuild internals are not extension contracts. If a
published workflow depends on one of these today, it receives a documented
replacement and deprecation window before removal.

## Internal Implementation

`LLMDB.Store`, `LLMDB.Loader`, `LLMDB.Runtime`, `LLMDB.Query`,
`LLMDB.Config`, `LLMDB.Packaged`, and the normalization, merge, validation, and
enrichment modules implement the stable contracts above. Their module layout,
internal maps, indexes, and call graph may change in a minor release when the
public behavior remains compatible.

The raw-snapshot accessor on `LLMDB` is intentionally hidden from the public
facade documentation. Consumers should use the typed query API or the versioned
`LLMDB.Snapshot` artifact instead.

## Deprecation Policy

Deprecations identify the supported replacement, remain callable for the stated
window, and are announced in release notes. Removing a stable runtime API,
struct field, accepted snapshot version, or supported maintainer task requires
a breaking release unless the API was already documented as transitional.

See [Using the Data](using-the-data.md) for runtime examples and
[Sources and Engine](sources-and-engine.md) for the build-time extension
contract. See [Runtime and Maintainer Boundaries](runtime-and-maintainer-boundaries.md)
for the complete module/dependency inventory and extraction sequence.
