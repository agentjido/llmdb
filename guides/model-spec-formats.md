# Model Spec Formats

Model specifications in LLMDB can be expressed in multiple formats to suit different use cases. This guide covers the supported formats and when to use each one.

## Overview

A **model spec** uniquely identifies an LLM model by combining a provider identifier and a model ID. LLMDB supports three formats:

1. **Colon format** (`"provider:model"`) - Traditional, human-readable
2. **@ format** (`"model@provider"`) - Filesystem-safe, email-like
3. **Tuple format** (`{:provider, "model_id"}`) - Internal representation

All three formats can be used interchangeably throughout the API.

## Provider Model ID Prefixes

Providers can declare model ID prefixes in their `extra` metadata:

```elixir
%{
  id: :openrouter,
  extra: %{model_id_prefixes: ["tenant.", "tenant.eu."]}
}
```

The same rules apply to each provider that declares prefixes:

- Use the longest matching prefix.
- Look for an exact prefixed entry first. It takes priority over a colliding base alias.
- If no exact entry exists, try the full ID as an alias, then the ID without its prefix.
- Keep the prefix when an alias or fallback resolves to a base model.
- Do not add a second prefix when the resolved entry already has a declared prefix.
- Use the metadata and price of the selected entry.
- Apply the same rules to qualified and bare resolution. Matches from different providers remain ambiguous.

Prefix rules do not apply to other providers. An empty `model_id_prefixes` list disables
prefix handling for that provider. Invalid or empty prefix strings are ignored.

Bedrock retains its built-in prefix defaults for existing catalogs. Provider metadata
can override those defaults. Prefix lookup does not change the stored model ID;
`LLMDB.Spec.resolve/2` returns the resolved route ID separately from the model object.

## Colon Format (Default)

```elixir
"openai:gpt-4o-mini"
"anthropic:claude-3-5-sonnet-20241022"
"google-vertex:gemini-1.5-pro"
```

### Syntax
- Provider comes first, followed by a colon, then the model ID
- Provider names with hyphens are normalized to underscores (e.g., `google-vertex` → `:google_vertex`)
- Model IDs can contain colons (e.g., `"bedrock:anthropic.claude-opus-4:0"`)

### When to Use
- Default choice for most cases
- Configuration files and user input
- Logs and error messages
- Documentation and examples

### Parsing

```elixir
{:ok, {:openai, "gpt-4o-mini"}} = LLMDB.parse("openai:gpt-4o-mini")
```

### Formatting

```elixir
"openai:gpt-4o-mini" = LLMDB.format({:openai, "gpt-4o-mini"})
# or explicitly
"openai:gpt-4o-mini" = LLMDB.format({:openai, "gpt-4o-mini"}, :provider_colon_model)
```

## @ Format (Filename-Safe)

```elixir
"gpt-4o-mini@openai"
"claude-3-5-sonnet-20241022@anthropic"
"gemini-1.5-pro@google_vertex"
```

### Syntax
- Model ID comes first, followed by an `@` symbol, then the provider
- Email-like semantics: `model@provider`
- No colons anywhere in the spec

### When to Use
- **Filenames**: Template files, cache files, logs
  ```elixir
  template_file = "system-prompt-#{LLMDB.format(spec, :filename_safe)}.liquid"
  # => "system-prompt-gpt-4o-mini@openai.liquid"
  ```
- **CI/CD artifacts**: Build artifacts, test results, benchmark data
  ```elixir
  artifact_path = "benchmarks/#{LLMDB.format(spec, :filename_safe)}/#{date}.json"
  # => "benchmarks/gpt-4o-mini@openai/2025-11-07.json"
  ```
- **URLs and paths**: S3 keys, API endpoints, file paths
- **Cross-platform compatibility**: Windows, macOS, Linux all accept `@` in filenames

### Parsing

```elixir
{:ok, {:openai, "gpt-4o-mini"}} = LLMDB.parse("gpt-4o-mini@openai")
```

### Formatting

```elixir
"gpt-4o-mini@openai" = LLMDB.format({:openai, "gpt-4o-mini"}, :filename_safe)
# or
"gpt-4o-mini@openai" = LLMDB.format({:openai, "gpt-4o-mini"}, :model_at_provider)
```

## Tuple Format (Internal)

```elixir
{:openai, "gpt-4o-mini"}
{:anthropic, "claude-3-5-sonnet-20241022"}
{:google_vertex, "gemini-1.5-pro"}
```

### Syntax
- Two-element tuple: `{provider_atom, model_id_string}`
- Accepted lookup inputs may use a provider atom or string; parsed tuples always contain the canonical atom with underscores
- Model ID is always a string

### When to Use
- Internal application state
- Pattern matching
- Function arguments when provider is already known
- Performance-critical code (avoids parsing overhead)

### Conversion

```elixir
# Parse to tuple
{:openai, "gpt-4o-mini"} = LLMDB.parse!("openai:gpt-4o-mini")

# String providers in tuple inputs normalize to the canonical atom
{:ok, {:google_vertex, "gemini-1.5-pro"}} =
  LLMDB.parse({"google-vertex", "gemini-1.5-pro"})

# Format from tuple
"openai:gpt-4o-mini" = LLMDB.format({:openai, "gpt-4o-mini"})
```

## Format Conversion

Use `LLMDB.build/2` to convert between formats:

```elixir
# Colon to @
"gpt-4@openai" = LLMDB.build("openai:gpt-4", format: :filename_safe)

# @ to colon
"openai:gpt-4" = LLMDB.build("gpt-4@openai", format: :provider_colon_model)

# Tuple to @
"gpt-4@openai" = LLMDB.build({:openai, "gpt-4"}, format: :model_at_provider)
```

## Automatic Format Detection

All parsing functions automatically detect which format you're using:

```elixir
# Both work seamlessly
{:ok, model} = LLMDB.model("openai:gpt-4o-mini")
{:ok, model} = LLMDB.model("gpt-4o-mini@openai")

# Parsing detects format automatically
{:ok, spec} = LLMDB.parse("openai:gpt-4")  # detects colon format
{:ok, spec} = LLMDB.parse("gpt-4@openai")  # detects @ format
```

## Ambiguous Input

If a spec contains both `:` and `@`, you must specify the format explicitly:

```elixir
# This is ambiguous - error!
{:error, :ambiguous_format} = LLMDB.parse("provider:model@test")

# Specify the format explicitly
{:ok, {:provider, "model@test"}} = LLMDB.parse("provider:model@test", format: :colon)
{:ok, {:test, "provider:model"}} = LLMDB.parse("provider:model@test", format: :at)
```

## Validation Rules

### Common Rules (Both Formats)
- Provider and model segments cannot be empty
- Leading/trailing whitespace is trimmed

### Colon Format Rules
- Provider cannot contain `:` or `@`
- Model ID can contain `:` (for Bedrock models like `"anthropic.claude-opus:0"`)
- Model ID cannot contain `@`

### @ Format Rules
- Provider cannot contain `:` or `@`
- Model ID can contain `@` (e.g., `"model@test@openai"` → provider is `openai`, model is `"model@test"`)
- Model ID cannot contain `:`

## Configuration

Set the default output format in your config:

```elixir
# config/config.exs
config :llm_db,
  model_spec_format: :provider_colon_model  # default
  # or
  model_spec_format: :model_at_provider     # filename-safe by default
```

Per-call overrides always take precedence:

```elixir
# Even if config says :model_at_provider, this returns colon format
"openai:gpt-4" = LLMDB.format(spec, :provider_colon_model)
```

## Use Case Examples

### Template Files

```elixir
defmodule MyApp.PromptLoader do
  def load(model_spec, template_name) do
    # Use @ format for filename safety
    model_str = LLMDB.format(model_spec, :filename_safe)
    path = Path.join(["templates", "#{template_name}-#{model_str}.liquid"])
    
    File.read!(path)
    # Reads: "templates/system-prompt-gpt-4o-mini@openai.liquid"
  end
end
```

### Oban Job Arguments

```elixir
defmodule MyApp.LLMWorker do
  use Oban.Worker
  
  def new(model_spec, prompt) do
    %{
      # Store as filename-safe string
      model: LLMDB.format(model_spec, :filename_safe),
      prompt: prompt
    }
    |> __MODULE__.new()
  end
  
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"model" => model_str, "prompt" => prompt}}) do
    # Parse from either format
    {:ok, {provider, model_id}} = LLMDB.parse(model_str)
    
    # Use the spec
    {:ok, model} = LLMDB.model(provider, model_id)
    # ...
  end
end
```

### Cache Keys

```elixir
defmodule MyApp.Cache do
  def cache_key(model_spec, input_hash) do
    # Use @ format for S3/filesystem compatibility
    model_str = LLMDB.format(model_spec, :filename_safe)
    "llm-cache/#{model_str}/#{input_hash}.json"
    # => "llm-cache/gpt-4o-mini@openai/abc123.json"
  end
end
```

### CI Artifacts

```elixir
defmodule MyApp.Benchmark do
  def artifact_path(model_spec, timestamp) do
    model_str = LLMDB.format(model_spec, :filename_safe)
    Path.join([
      "benchmark-results",
      model_str,
      "#{timestamp}.json"
    ])
    # => "benchmark-results/gpt-4o-mini@openai/2025-11-07T10:30:00Z.json"
  end
end
```

## Migration Guide

If you want to adopt the `@` format for existing stored specs:

### Option 1: Support Both Formats (Recommended)

No migration needed - just use the new format going forward:

```elixir
# Old data uses colon format
old_spec = "openai:gpt-4"
{:ok, model} = LLMDB.model(old_spec)  # still works

# New data uses @ format
new_spec = LLMDB.format({:openai, "gpt-4"}, :filename_safe)
{:ok, model} = LLMDB.model(new_spec)  # also works
```

### Option 2: Migrate Stored Data

For databases or files storing specs as strings:

```elixir
defmodule MyApp.MigrateSpecs do
  def run do
    MyApp.Repo.all(MyApp.Record)
    |> Enum.each(fn record ->
      # Parse old format
      {:ok, spec} = LLMDB.parse(record.model_spec)
      
      # Format in new format
      new_spec = LLMDB.format(spec, :model_at_provider)
      
      # Update record
      record
      |> Ecto.Changeset.change(model_spec: new_spec)
      |> MyApp.Repo.update!()
    end)
  end
end
```

### Option 3: Set Global Default

Change the default output format:

```elixir
# config/config.exs
config :llm_db,
  model_spec_format: :model_at_provider
```

Now all `LLMDB.format/1` calls (without explicit format) return `@` format:

```elixir
"gpt-4@openai" = LLMDB.format({:openai, "gpt-4"})
```

## Best Practices

1. **Use colon format by default** - It's more familiar and readable
2. **Use @ format for filenames** - Avoids cross-platform issues
3. **Use tuples internally** - Skip parsing overhead when provider is known
4. **Let auto-detection work** - Don't specify `:format` unless dealing with ambiguous input
5. **Document your choice** - Make it clear which format your system expects
6. **Be consistent** - Pick one format for logs, another for files, and stick with it

## Summary

| Format | Syntax | Use Case | Example |
|--------|--------|----------|---------|
| Colon | `"provider:model"` | Default, human-readable | `"openai:gpt-4o-mini"` |
| @ | `"model@provider"` | Filenames, URLs, cross-platform | `"gpt-4o-mini@openai"` |
| Tuple | `{:provider, "model"}` | Internal, performance-critical | `{:openai, "gpt-4o-mini"}` |

All three formats are fully supported and can be used interchangeably throughout the LLMDB API.
