defmodule LLMDB.Provider do
  @moduledoc """
  Provider struct with Zoi schema validation.

  Represents an LLM provider with metadata including identity, base URL,
  environment variables, documentation, and pricing defaults.

  ## Fields

  - `:id` - Unique provider identifier atom (e.g., `:openai`)
  - `:name` - Display name
  - `:base_url` - Base API URL (supports template variables like `{region}`)
  - `:env` - List of environment variable names for credentials
  - `:config_schema` - Runtime configuration field definitions
  - `:doc` - Documentation URL
  - `:pricing_defaults` - Default pricing components applied to all models (see below)
  - `:exclude_models` - Model IDs to exclude from upstream sources
  - `:extra` - Additional provider-specific data; snapshot JSON keys remain strings
  - `:alias_of` - Primary provider ID if this is an alias

  ## Model ID Prefixes

  Set `extra.model_id_prefixes` to declare prefixes for model lookup. For example,
  `%{extra: %{model_id_prefixes: ["tenant.", "tenant.eu."]}}` enables exact prefixed
  entries, aliases, and base model fallback for that provider. The longest matching
  prefix is used. Base aliases and fallbacks retain the prefix in the resolved ID.
  If that resolved ID names a prefixed entry, its metadata and pricing are used.

  Providers without prefix rules use ordinary model and alias lookup. Bedrock has
  compatibility defaults for existing catalogs. An explicit empty list disables them.

  ## Pricing Defaults

  The `:pricing_defaults` field defines default pricing for tools and features
  that apply to all models from this provider. This avoids duplicating tool
  pricing across every model definition.

      %{
        currency: "USD",
        components: [
          %{id: "tool.web_search", kind: "tool", tool: "web_search", unit: "call", per: 1000, rate: 10.0},
          %{id: "storage.vectors", kind: "storage", unit: "gb_day", per: 1, rate: 0.10}
        ]
      }

  Provider defaults are merged with model-specific pricing at load time.
  See `LLMDB.Pricing` and the [Pricing and Billing guide](pricing-and-billing.md).
  """

  @config_field_schema Zoi.object(%{
                         name: Zoi.string(),
                         type: Zoi.string(),
                         required: Zoi.boolean() |> Zoi.default(false),
                         default: Zoi.any() |> Zoi.nullish(),
                         doc: Zoi.string() |> Zoi.nullish()
                       })

  @pricing_defaults_schema LLMDB.Schema.Pricing.schema()

  @runtime_auth_header_schema Zoi.object(%{
                                name: Zoi.string(),
                                env: Zoi.string() |> Zoi.nullish(),
                                value: Zoi.string() |> Zoi.nullish()
                              })

  @runtime_auth_schema Zoi.object(%{
                         type:
                           Zoi.enum(["bearer", "x_api_key", "header", "query", "multi_header"])
                           |> Zoi.nullish(),
                         env: Zoi.array(Zoi.string()) |> Zoi.default([]),
                         header_name: Zoi.string() |> Zoi.nullish(),
                         query_name: Zoi.string() |> Zoi.nullish(),
                         headers: Zoi.array(@runtime_auth_header_schema) |> Zoi.default([])
                       })

  @runtime_execution_schema Zoi.object(%{
                              text: Zoi.string() |> Zoi.nullish(),
                              object: Zoi.string() |> Zoi.nullish(),
                              evaluate: Zoi.string() |> Zoi.nullish(),
                              embed: Zoi.string() |> Zoi.nullish(),
                              image: Zoi.string() |> Zoi.nullish(),
                              transcription: Zoi.string() |> Zoi.nullish(),
                              speech: Zoi.string() |> Zoi.nullish(),
                              realtime: Zoi.string() |> Zoi.nullish()
                            })

  @runtime_schema Zoi.object(%{
                    base_url: Zoi.string() |> Zoi.nullish(),
                    auth: @runtime_auth_schema |> Zoi.nullish(),
                    default_headers: Zoi.map() |> Zoi.default(%{}),
                    default_query: Zoi.map() |> Zoi.default(%{}),
                    config_schema: Zoi.array(@config_field_schema) |> Zoi.nullish(),
                    doc_url: Zoi.string() |> Zoi.nullish(),
                    execution: @runtime_execution_schema |> Zoi.nullish()
                  })

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.atom(),
              name: Zoi.string() |> Zoi.nullish(),
              base_url: Zoi.string() |> Zoi.nullish(),
              env: Zoi.array(Zoi.string()) |> Zoi.nullish(),
              config_schema: Zoi.array(@config_field_schema) |> Zoi.nullish(),
              doc: Zoi.string() |> Zoi.nullish(),
              exclude_models: Zoi.array(Zoi.string()) |> Zoi.default([]) |> Zoi.nullish(),
              pricing_defaults: @pricing_defaults_schema |> Zoi.nullish(),
              runtime: @runtime_schema |> Zoi.nullish(),
              catalog_only: Zoi.boolean() |> Zoi.default(false),
              extra: Zoi.map() |> Zoi.nullish(),
              alias_of: Zoi.atom() |> Zoi.nullish()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for Provider"
  def schema, do: @schema

  @doc """
  Creates a new Provider struct from a map, validating with Zoi schema.

  ## Examples

      iex> LLMDB.Provider.new(%{id: :openai, name: "OpenAI"})
      {:ok, %LLMDB.Provider{id: :openai, name: "OpenAI"}}

      iex> LLMDB.Provider.new(%{})
      {:error, _validation_errors}
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> normalize_runtime_attrs()

    Zoi.parse(@schema, attrs)
  end

  @doc """
  Creates a new Provider struct from a map, raising on validation errors.

  ## Examples

      iex> LLMDB.Provider.new!(%{id: :openai, name: "OpenAI"})
      %LLMDB.Provider{id: :openai, name: "OpenAI"}
  """
  @spec new!(map()) :: t()
  def new!(attrs) when is_map(attrs) do
    case new(attrs) do
      {:ok, provider} -> provider
      {:error, reason} -> raise ArgumentError, "Invalid provider: #{inspect(reason)}"
    end
  end

  defp normalize_runtime_attrs(attrs) do
    update_in_nested_map(attrs, :runtime, fn runtime ->
      update_in_nested_map(runtime, :auth, fn auth ->
        normalize_string_enum(auth, :type)
      end)
    end)
  end

  defp update_in_nested_map(attrs, key, fun) when is_map(attrs) do
    case Map.get(attrs, key) || Map.get(attrs, to_string(key)) do
      nested when is_map(nested) ->
        normalized = fun.(nested)

        attrs
        |> Map.put(key, normalized)
        |> Map.put(to_string(key), normalized)

      _other ->
        attrs
    end
  end

  defp normalize_string_enum(map, key) when is_map(map) do
    value = Map.get(map, key) || Map.get(map, to_string(key))

    normalized =
      case value do
        atom when is_atom(atom) -> Atom.to_string(atom)
        other -> other
      end

    map
    |> Map.put(key, normalized)
    |> Map.put(to_string(key), normalized)
  end
end
