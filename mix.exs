defmodule LLMDB.MixProject do
  use Mix.Project

  @version "2026.8.1"
  @source_url "https://github.com/agentjido/llm_db"
  @description "LLM model metadata catalog with fast, capability-aware lookups."

  def project do
    [
      app: :llm_db,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description: @description,
      package: package(),
      elixirc_paths: elixirc_paths(Mix.env()),
      test_coverage: [summary: [threshold: 50]],

      # Dialyzer configuration
      dialyzer: [
        plt_add_apps: [:mix]
      ],

      # Documentation
      name: "LLM DB",
      source_url: @source_url,
      homepage_url: @source_url,
      source_ref: @version,
      docs: [
        main: "readme",
        extras: [
          "README.md",
          "guides/api-and-support-policy.md",
          "guides/consumer-integration.md",
          "guides/model-spec-formats.md",
          "guides/model-struct-evolution-proposal.md",
          "guides/package-footprint.md",
          "guides/snapshot-formats.md",
          "guides/pricing-and-billing.md",
          "guides/runtime-and-maintainer-boundaries.md",
          "guides/schema-system.md",
          "guides/sources-and-engine.md",
          "guides/runtime-filters.md",
          "guides/using-the-data.md",
          "guides/release-process.md",
          "CHANGELOG.md"
        ],
        groups_for_extras: [
          Guides: ~r/guides\/.+\.md/
        ],
        groups_for_modules: [
          "Stable Runtime API": [
            LLMDB,
            LLMDB.History,
            LLMDB.LoadError,
            LLMDB.Model,
            LLMDB.Provider,
            LLMDB.Spec
          ],
          "Supported Build Extensions": [
            LLMDB.Snapshot,
            LLMDB.Source
          ],
          "Supported Mix Tasks": [
            ~r/^Mix\.Tasks\.LlmDb\./
          ],
          "Compatibility Facades": [
            LLMDB.Application,
            LLMDB.Dotenv,
            LLMDB.Store
          ],
          "Maintainer Internals": [
            LLMDB.Engine,
            LLMDB.Snapshot.Builder,
            ~r/^LLMDB\.(Enrich|History|Validate)(\.|$)/,
            ~r/^LLMDB\.Sources\./
          ],
          "Internal Runtime Implementation": [
            LLMDB.Snapshot.ReleaseStore,
            ~r/^LLMDB\.(Catalog|Config|Generated|Loader|Merge|Normalize|Packaged|Pricing|Query|Runtime)(\.|$)/
          ]
        ]
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:zoi, "~> 0.10"},
      {:jason, "~> 1.4"},
      {:toml, "~> 0.7"},
      {:req, "~> 0.5"},
      {:dotenvy, "~> 1.1"},
      {:plug, "~> 1.16", only: :test},
      {:meck, "~> 1.0", only: :test},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:git_ops, "~> 2.6", only: :dev, runtime: false},
      {:git_hooks, "~> 0.8", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:usage_rules, "~> 1.0", only: :dev, runtime: false},
      {:igniter, "~> 0.7", optional: true}
    ]
  end

  defp package do
    [
      description: @description,
      licenses: ["Apache-2.0"],
      maintainers: ["Mike Hostetler"],
      links: %{
        "Changelog" => "https://hexdocs.pm/llm_db/changelog.html",
        "Discord" => "https://agentjido.xyz/discord",
        "Documentation" => "https://hexdocs.pm/llm_db",
        "GitHub" => @source_url,
        "Website" => "https://agentjido.xyz"
      },
      files:
        ~w(config guides lib priv/llm_db/snapshot.json mix.exs LICENSE README.md CHANGELOG.md)
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --min-priority higher",
        "dialyzer"
      ],
      q: ["quality"]
    ]
  end
end
