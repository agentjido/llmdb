defmodule LLMDB.ModelResolver.Defaults do
  @moduledoc false

  # Compatibility defaults for catalogs that predate provider prefix metadata.
  @prefix_rules %{amazon_bedrock: ~w(us. eu. ap. apac. ca. au. jp. us-gov. global.)}

  @spec prefix_rules() :: %{atom() => [String.t()]}
  def prefix_rules, do: @prefix_rules
end
