# Consumer Integration Guide

Guide for libraries and applications consuming llm_db for model metadata.

## Overview

llm_db provides model metadata through a simple `model_spec` interface with alias resolution. This guide covers best practices for integrating llm_db into your library or application.

## Model Aliases and Canonical IDs

### Understanding the Alias System

llm_db uses **canonical IDs** with **alias resolution** to handle model naming variations:

- **Canonical ID**: The primary, immutable identifier for a model (typically the dated version)
  - Example: `claude-haiku-4-5-20251001`
- **Aliases**: Alternative names that resolve to the canonical ID
  - Examples: `claude-haiku-4-5`, `claude-haiku-4.5`, `claude-haiku-4-5@latest`

```elixir
# All of these resolve to the same model
LLMDB.model("anthropic:claude-haiku-4-5-20251001")  #=> canonical
LLMDB.model("anthropic:claude-haiku-4-5")            #=> alias → canonical
LLMDB.model("anthropic:claude-haiku-4.5")            #=> alias → canonical
# All return: %LLMDB.Model{id: "claude-haiku-4-5-20251001", ...}
```

### Why Canonical IDs?

1. **Immutable**: Dated versions represent a single, specific model release
2. **Deduplication**: Prevents duplicate metadata/fixtures for the same model
3. **Clarity**: Explicit about which version you're using
4. **Stability**: Won't change when "latest" changes

### Alias Resolution Flow

```
User Request → Alias Resolution → Canonical Model → Metadata
"claude-haiku-4.5" → "claude-haiku-4-5-20251001" → %LLMDB.Model{...}
```

## Configuration: allow/deny Filters

### Critical Rule: Filters Use Canonical IDs Only

**Filters are applied BEFORE alias resolution**, so they match against canonical IDs, not aliases.

```elixir
# ✓ CORRECT - Use canonical IDs in filters
config :llm_db,
  filter: %{
    allow: %{
      anthropic: [
        "claude-haiku-4-5-20251001",      # Canonical ID
        "claude-opus-4-1-20250805",       # Canonical ID
        "claude-sonnet-4-5-20250929"      # Canonical ID
      ]
    },
    deny: %{}
  }

# ✗ INCORRECT - Aliases won't match
config :llm_db,
  filter: %{
    allow: %{
      anthropic: [
        "claude-haiku-4.5",    # This is an alias - won't work!
        "claude-opus-4.1",     # This is an alias - won't work!
        "claude-sonnet-4.5"    # This is an alias - won't work!
      ]
    },
    deny: %{}
  }
# This will eliminate ALL models because aliases don't match filters
```

### Using Glob Patterns

Glob patterns work with canonical IDs:

```elixir
config :llm_db,
  filter: %{
    allow: %{
      anthropic: ["claude-haiku-*"],    # Matches claude-haiku-4-5-20251001
      openai: ["gpt-4o-*"]               # Matches gpt-4o-2024-11-20, etc.
    },
    deny: %{
      anthropic: ["*-thinking"]          # Deny thinking modes
    }
  }
```

### Finding Canonical IDs

Use llm_db to discover canonical IDs for configuration:

```elixir
# List all models for a provider
anthropic_models = LLMDB.models(:anthropic)
Enum.each(anthropic_models, fn m ->
  IO.puts("#{m.id} → aliases: #{inspect(m.aliases)}")
end)

# Output:
# claude-haiku-4-5-20251001 → aliases: ["claude-haiku-4-5", "claude-haiku-4.5"]
# claude-opus-4-1-20250805 → aliases: ["claude-opus-4-1", "claude-opus-4.1"]
```

## Fixture Management

### Best Practice: One Fixture Set per Canonical ID

Since aliases resolve to canonical IDs, you only need ONE fixture set per unique model.

**Example Directory Structure:**

```
fixtures/
├── anthropic/
│   ├── claude-haiku-4-5-20251001/    # ✓ One canonical fixture
│   │   ├── basic.json
│   │   ├── tools.json
│   │   └── streaming.json
│   ├── claude-opus-4-1-20250805/      # ✓ One canonical fixture
│   │   └── basic.json
│   └── claude-sonnet-4-5-20250929/    # ✓ One canonical fixture
│       └── basic.json
```

**Anti-pattern (duplicates):**

```
fixtures/
├── anthropic/
│   ├── claude-haiku-4-5-20251001/    # ✗ Duplicate
│   ├── claude-haiku-4-5/             # ✗ Duplicate (alias)
│   └── claude-haiku-4.5/             # ✗ Duplicate (alias)
```

### Fixture Lookup Strategy

When looking up fixtures, resolve to canonical ID first:

```elixir
defmodule MyApp.Fixtures do
  def load_fixture(model_spec) do
    # Resolve to canonical model
    {:ok, model} = LLMDB.model(model_spec)
    
    # Use canonical ID for fixture path
    provider = model.provider
    canonical_id = model.id
    
    fixture_path = "test/fixtures/#{provider}/#{canonical_id}/basic.json"
    File.read!(fixture_path)
  end
end

# All of these load the same fixture
MyApp.Fixtures.load_fixture("anthropic:claude-haiku-4-5-20251001")
MyApp.Fixtures.load_fixture("anthropic:claude-haiku-4-5")
MyApp.Fixtures.load_fixture("anthropic:claude-haiku-4.5")
```

## Runtime Model Resolution

### Accept Any Variant, Use Canonical Internally

Allow users to specify models using aliases, but resolve to canonical IDs internally:

```elixir
defmodule MyApp.LLMClient do
  def chat(model_spec, messages) do
    # Resolve alias to canonical model
    {:ok, model} = LLMDB.model(model_spec)
    
    # Use canonical ID internally
    provider = model.provider
    canonical_id = model.id
    
    # Make API call with metadata
    request_body = %{
      model: model.provider_model_id || canonical_id,  # Use provider-specific ID
      messages: messages,
      max_tokens: model.limits.output
    }
    
    make_request(provider, request_body)
  end
end

# All variants work
MyApp.LLMClient.chat("anthropic:claude-haiku-4.5", messages)  # Alias
MyApp.LLMClient.chat("anthropic:claude-haiku-4-5-20251001", messages)  # Canonical
```

## Migration: Consolidating Duplicates

If you have existing code/fixtures using aliases, migrate to canonical IDs:

### Step 1: Identify Duplicates

```elixir
# Find models with aliases
anthropic_models = LLMDB.models(:anthropic)
duplicates = Enum.filter(anthropic_models, fn m -> length(m.aliases) > 0 end)

Enum.each(duplicates, fn m ->
  IO.puts("Canonical: #{m.id}")
  IO.puts("  Aliases: #{inspect(m.aliases)}")
end)
```

### Step 2: Update Configuration

Replace aliases with canonical IDs in `config/*.exs`:

```elixir
# Before
config :my_app,
  allowed_models: [
    "anthropic:claude-haiku-4.5",     # Alias
    "anthropic:claude-opus-4.1"       # Alias
  ]

# After
config :my_app,
  allowed_models: [
    "anthropic:claude-haiku-4-5-20251001",    # Canonical
    "anthropic:claude-opus-4-1-20250805"      # Canonical
  ]
```

### Step 3: Consolidate Fixtures

Rename fixture directories to canonical IDs and remove duplicates:

```bash
# Rename to canonical
mv fixtures/anthropic/claude_haiku_4_5 fixtures/anthropic/claude-haiku-4-5-20251001

# Remove duplicates
rm -rf fixtures/anthropic/claude-haiku-4.5
rm -rf fixtures/anthropic/claude_haiku_4.5_20251001
```

### Step 4: Update Tests

Update test references to use canonical IDs:

```elixir
# Before
test "claude haiku generates text" do
  response = MyApp.chat("anthropic:claude-haiku-4.5", "Hello")
  assert response.text
end

# After (optional - aliases still work at runtime)
test "claude haiku generates text" do
  response = MyApp.chat("anthropic:claude-haiku-4-5-20251001", "Hello")
  assert response.text
end

# Or keep using aliases - both work!
test "claude haiku generates text" do
  # This still works - llm_db resolves the alias
  response = MyApp.chat("anthropic:claude-haiku-4.5", "Hello")
  assert response.text
end
```

## Common Patterns

### Allow User Preferences, Resolve Internally

```elixir
defmodule MyApp.Config do
  def get_preferred_model do
    # Users configure with any variant
    model_spec = Application.get_env(:my_app, :default_model, "anthropic:claude-haiku-4.5")
    
    # Resolve to canonical for internal use
    case LLMDB.model(model_spec) do
      {:ok, model} -> {:ok, {model.provider, model.id}}
      error -> error
    end
  end
end
```

### Validate Model Availability

```elixir
defmodule MyApp.Setup do
  def validate_config! do
    configured_models = Application.get_env(:my_app, :allowed_models, [])
    
    Enum.each(configured_models, fn model_spec ->
      case LLMDB.model(model_spec) do
        {:ok, model} ->
          unless LLMDB.allowed?(model) do
            raise "Model #{model_spec} is filtered out by llm_db configuration"
          end
          IO.puts("✓ #{model_spec} → #{model.provider}:#{model.id}")
          
        {:error, :not_found} ->
          raise "Model #{model_spec} not found in llm_db catalog"
      end
    end)
  end
end
```

## Recommendations Summary

1. **Filters**: Always use canonical IDs in allow/deny patterns
2. **Fixtures**: One fixture set per canonical model ID
3. **Configuration**: Use canonical IDs in application config
4. **Runtime**: Accept user input with aliases, resolve to canonical internally
5. **Documentation**: Document canonical IDs in user-facing docs, mention alias support
6. **Migration**: Consolidate duplicate fixtures to canonical IDs
7. **Validation**: Check both model existence and filter status at startup

## See Also

- [Using the Data](using-the-data.md) - Alias resolution examples
- [Runtime Filters](runtime-filters.md) - Filter configuration details
- [Schema System](schema-system.md) - Model alias field documentation


## Get metadata outside the local catalog

`LLMDB.model/1` uses the local catalog. Use `LLMDB.fetch_model/2` to make an
explicit request for one exact offer. The result contains display, pricing,
and lifecycle metadata. Use your local configuration for execution.

```elixir
LLMDB.model({:openrouter, "openai/gpt-3.5-turbo-0613"})
LLMDB.fetch_model({:openrouter, "openai/gpt-3.5-turbo-0613"}, timeout: 5_000)
```

For bulk use, download `catalog-full.json` and `catalog-manifest.json` from the
GitHub release that matches your dependency version. Compare the manifest's
release version, snapshot ID, byte count, and SHA-256 with the download before
loading it. Pass the verified file to `LLMDB.load/1` from an application that
needs to use the complete catalog offline.

```elixir
LLMDB.load(snapshot_source: {:file, "/path/to/catalog-full.json"})
```
