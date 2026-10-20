defmodule Composer.MixProject do
  use Mix.Project

  @version "0.2.1"
  @source_url "https://github.com/elixir-composer/composer"

  def project do
    [
      app: :composer,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      description: "Composable project setup for Elixir applications, built on Igniter",
      source_url: @source_url,
      deps: deps(),
      # test/fixtures holds a whole Mix project used by the integration test.
      test_ignore_filters: [&String.starts_with?(&1, "test/fixtures/")],
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:commit_hook, "~> 0.5", only: [:dev], runtime: false},
      {:git_ops, "~> 2.0", only: [:dev], runtime: false},
      {:igniter, "~> 0.6"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:gen_lsp, "~> 0.11.4"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      maintainers: ["Andy Leak"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/master/CHANGELOG.md"
      },
      files: ~w(lib priv .formatter.exs mix.exs README* LICENSE* CHANGELOG*)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "guides/cookbooks.md",
        "guides/recipes.md",
        "guides/templates.md",
        "guides/lint.md",
        "guides/composer_lsp.md",
        "CHANGELOG.md",
        "LICENSE.md"
      ],
      groups_for_extras: [Guides: ~r{guides/}],
      groups_for_modules: [
        Definitions: [Composer.Step, Composer.Step.Meta, Composer.Cookbook, Composer.Facets],
        "Recipes and references": [
          Composer.Recipe,
          Composer.Recipe.Group,
          Composer.Ref,
          Composer.Resolver,
          Composer.Local,
          Composer.Discovery
        ],
        "Writing steps": [Composer.Templates, Composer.Helpers, Composer.Versions],
        Engine: [Composer.Runner, Composer.Preflight, Composer.Git, Composer.Error],
        Tooling: [
          Composer.Manifest,
          Composer.Index,
          Composer.Lint,
          Composer.Lint.Diagnostic,
          Composer.Lint.Format,
          Composer.Recipe.Locator
        ],
        Editor: [Composer.LSP, ~r/^Composer.LSP./, Mix.Tasks.Composer.Lsp],
        Cookbooks: [Composer.Core],
        "Built-in steps": ~r/^Composer.Core.Steps./
      ]
    ]
  end
end
