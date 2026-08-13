# Runtime Filters

Runtime filtering allows you to control which models are visible at load-time and during runtime without rebuilding the packaged snapshot.

## Overview

LLMDB separates build-time and load-time concerns:

- **Build-time** (Engine): Produces complete, unfiltered snapshots from sources
- **Load-time** (LLMDB.load): Applies filters and builds indexes
- **Runtime** (Runtime.apply): Updates filters dynamically without reload

The `base_models` list stored in the snapshot enables widening filters later without rebuilding from sources.

## Initialization

The packaged catalog initializes lazily on the first public query. The library
does not register an OTP application callback and starts no supervisor or
worker. Concurrent first queries share one process-free initialization lock,
while later queries only read the published immutable catalog.

Lazy initialization uses the configured packaged, file, or release snapshot
source and applies the same filters and custom data as `LLMDB.load/1`. It never
pulls upstream provider metadata or loads dotenv files. Set
`skip_packaged_load: true` to leave the catalog empty until an explicit load.

To keep the load outside the first request, call `LLMDB.load/0` at the start of
your consumer application's `start/2` callback, before you start its supervision
tree:

```elixir
def start(_type, _args) do
  with {:ok, _snapshot} <- LLMDB.load() do
    MyApp.Supervisor.start_link(name: MyApp.Supervisor)
  end
end
```

With strict integrity checking, an invalid snapshot fails this explicit preload
with `{:error, reason}`. Without a preload, it raises `LLMDB.LoadError` on the
first query.

## Configuration Model

### Keys

Configure filters using the `:filter` key in your application config:

```elixir
config :llm_db,
  filter: %{
    allow: :all | %{provider_atom => [pattern_strings]},
    deny: %{provider_atom => [pattern_strings]}
  }
```

### Semantics

| Configuration | Behavior |
|--------------|----------|
| `allow: :all` | Everything passes unless denied (default) |
| `allow: %{}` | Same as `:all` (empty map) |
| `allow: %{provider: []}` | Blocks provider entirely |
| `allow: %{provider: ["pattern*"]}` | Only matching models pass |
| `deny: %{provider: ["pattern*"]}` | Always overrides allow |

**Provider Keys:**
- Accept atoms (`:openai`) or strings (`"openai"`)
- Unknown providers are warned and ignored
- Must correspond to existing provider atoms

**Pattern Types:**
- Glob: `"gpt-4*"`, `"*-preview"`, `"claude-3-haiku-*"`
- Regex: `~r/gpt-4.*/`, `~r/claude-3-\w+-20240307/`
- Globs compile to anchored regex for matching

## Common Recipes

### Allow only Haiku models across providers

```elixir
config :llm_db,
  filter: %{
    allow: %{
      anthropic: ["claude-3-haiku-*"],
      openrouter: ["anthropic/claude-3-haiku-*"]
    },
    deny: %{}
  }
```

### Allow all except preview/beta models

```elixir
config :llm_db,
  filter: %{
    allow: :all,
    deny: %{
      openai: ["*-preview", "*-beta"],
      google: ["*-experimental"]
    }
  }
```

### Block a provider entirely

```elixir
config :llm_db,
  filter: %{
    allow: %{
      openai: [],  # Empty list blocks provider
      anthropic: ["claude-3-*"]
    },
    deny: %{}
  }
```

Alternatively, simply omit the provider from a non-empty allow map:

```elixir
config :llm_db,
  filter: %{
    allow: %{
      anthropic: ["claude-3-*"]
      # openai implicitly blocked (not in allow map)
    },
    deny: %{}
  }
```

### Carve out exceptions with deny

```elixir
config :llm_db,
  filter: %{
    allow: %{anthropic: ["claude-3-haiku-*"]},
    deny: %{anthropic: ["*-legacy"]}
  }
```

This allows all Haiku models except legacy versions.

### Runtime override to switch families

Start with one configuration:

```elixir
# config/runtime.exs
config :llm_db,
  filter: %{
    allow: %{anthropic: ["claude-3-haiku-*"]},
    deny: %{}
  }
```

Then override at runtime to switch to different models:

```elixir
{:ok, _snapshot} = LLMDB.load(
  runtime_overrides: %{
    filter: %{
      allow: %{
        anthropic: ["claude-3.5-sonnet-*", "claude-3-opus-*"]
      },
      deny: %{}
    }
  }
)
```

### Programmatic update without reload

For hot updates during runtime without calling `load/1`:

```elixir
# Get current snapshot
snapshot = LLMDB.Store.snapshot()

# Apply new filters
{:ok, updated_snapshot} = LLMDB.Runtime.apply(snapshot, %{
  filter: %{
    allow: %{openai: ["gpt-4o-*"]},
    deny: %{openai: ["*-preview"]}
  }
})

# Update store (atomic swap)
LLMDB.Store.put!(updated_snapshot)
```

The `Runtime.apply/2` function:
- Recompiles filters and reapplies to `base_models`
- Rebuilds indexes (models_by_key, aliases_by_key, models_by_provider)
- Enables filter widening because it uses the full `base_models` list
- Returns `{:ok, snapshot}` or `{:error, reason}`

## Runtime Overrides

### Via LLMDB.load/1

Pass `runtime_overrides` to override config at load time:

```elixir
{:ok, _snapshot} = LLMDB.load(
  runtime_overrides: %{
    filter: %{allow: %{...}, deny: %{...}},
    prefer: [:openai, :anthropic]
  }
)
```

Runtime overrides take precedence over application config.

### Via LLMDB.Runtime.apply/2

For updates without reloading:

```elixir
snapshot = LLMDB.Store.snapshot()

{:ok, updated_snapshot} = LLMDB.Runtime.apply(snapshot, %{
  filter: %{...}
})

LLMDB.Store.put!(updated_snapshot)
```

## Error Handling and Troubleshooting

### "Filters eliminated all models"

**Error:**
```
{:error, "llm_db: filters eliminated all models (allow: ..., deny: ...). 
 Use allow: :all to widen filters or remove deny patterns."}
```

**Causes:**
- Allow patterns match no models
- All models are denied
- Unknown providers in allow map (silently ignored, leaving no valid providers)

**Solutions:**
1. Check provider names for typos
2. Verify patterns match actual model IDs
3. Use `allow: :all` to widen filters
4. Remove or adjust deny patterns

### "Unknown providers in filter"

**Warning:**
```
llm_db: unknown provider(s) in filter: [:unknwon_provider]. 
Known providers: [:openai, :anthropic, ...]. 
Check spelling or remove unknown providers from configuration.
```

**Causes:**
- Typo in provider name
- Provider doesn't exist in snapshot
- String not converted to existing atom

**Solutions:**
1. Check spelling: `:openai` not `:open_ai`
2. Verify provider exists: `LLMDB.providers()` or `LLMDB.list_providers()`
3. Remove unknown provider from config

### Nothing shows for provider X

With a non-empty allow map, providers must be explicitly listed:

```elixir
# This BLOCKS openai (not in allow map)
config :llm_db,
  filter: %{
    allow: %{anthropic: ["claude-3-*"]},  # Only anthropic allowed
    deny: %{}
  }

# To include openai, add it to allow:
config :llm_db,
  filter: %{
    allow: %{
      anthropic: ["claude-3-*"],
      openai: ["gpt-4*"]
    },
    deny: %{}
  }
```

### Check what's allowed

```elixir
LLMDB.allowed?("openai:gpt-4o-mini")  
#=> true or false

LLMDB.allowed?({:openai, "gpt-4o-preview"})
#=> false (if denied by pattern)

{:ok, model} = LLMDB.model("openai:gpt-4o-mini")
LLMDB.allowed?(model)
#=> true
```

## Safety and Performance

### Provider Key Safety

- Provider keys use `String.to_existing_atom/1` to prevent atom leaks
- Unknown string keys are ignored with warnings
- Atom keys are validated against known providers
- Safe for use in production with untrusted config sources

### Pattern Performance

- Patterns compile once at load/override time
- Runtime matching is O(patterns-for-provider) per `allowed?/1` call
- Regex patterns are compiled and cached
- Typical pattern counts (<100 per provider) have negligible overhead

**Recommendations:**
- Prefer glob patterns (`"gpt-4*"`) over complex regex for readability
- Avoid untrusted user input for Regex patterns (config should be trusted)
- For thousands of patterns, consider pre-filtering at source level

### Filter Widening

Runtime filter updates can widen or narrow because they operate on `base_models`:

```elixir
# Start narrow
LLMDB.load(runtime_overrides: %{
  filter: %{allow: %{anthropic: ["claude-3-haiku-*"]}, deny: %{}}
})
#=> Only Haiku models visible

# Widen later
snapshot = LLMDB.Store.snapshot()
{:ok, snapshot} = LLMDB.Runtime.apply(snapshot, %{
  filter: %{allow: %{anthropic: ["claude-3-*"]}, deny: %{}}
})
LLMDB.Store.put!(snapshot)
#=> All Claude 3 models now visible (pulled from base_models)
```

## Edge Cases

### Empty allow map

```elixir
config :llm_db,
  filter: %{allow: %{}, deny: %{}}
```

This behaves like `allow: :all` (map size is 0).

### Allow with only unknown providers

```elixir
config :llm_db,
  filter: %{
    allow: %{nonexistent_provider: ["model-*"]},
    deny: %{}
  }
```

After filtering out unknown providers, allow becomes `%{}` (empty map), which acts like `:all`. You'll see a warning but load will succeed.

To actually restrict to specific providers, use known provider names:

```elixir
config :llm_db,
  filter: %{
    allow: %{anthropic: ["claude-3-haiku-*"]},
    deny: %{}
  }
```

### Regex safety

Regex from application config is trusted. Avoid accepting user-supplied Regex patterns:

```elixir
# Safe: config file
config :llm_db,
  filter: %{allow: %{openai: [~r/gpt-4.*/]}, deny: %{}}

# Unsafe: user input (don't do this)
user_pattern = ~r/#{user_input}.*/  # Potential ReDoS attack
```

Stick to glob patterns for user-facing configuration.

## Migration from Old Format

If you previously used top-level `:allow` and `:deny` keys:

**Old:**
```elixir
config :llm_db,
  allow: %{openai: ["gpt-4*"]},
  deny: %{openai: ["*-preview"]}
```

**New:**
```elixir
config :llm_db,
  filter: %{
    allow: %{openai: ["gpt-4*"]},
    deny: %{openai: ["*-preview"]}
  }
```

The old format is no longer supported as of version 2025.11.7+. Update your configuration to use the singular `:filter` key.
