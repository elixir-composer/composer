defmodule ComposerNew.MixProject do
  use Mix.Project

  # Lockstep with composer's mix.exs: git_ops bumps both (managed_files in
  # ../config/config.exs). Don't edit by hand.
  @version "0.3.0"
  @source_url "https://github.com/elixir-composer/composer"

  def project do
    [
      app: :composer_new,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      description: "mix composer.new: create an Elixir app and apply a composer recipe",
      source_url: @source_url,
      deps: deps(),
      test_ignore_filters: [&String.starts_with?(&1, "test/fixtures/")],
      package: package(),
      docs: docs()
    ]
  end

  # An archive loads into every Mix project, so it starts nothing and needs
  # no applications beyond what Mix already runs.
  def application do
    [extra_applications: []]
  end

  # Never a runtime dep: an archive can't carry deps.
  defp deps do
    [{:ex_doc, "~> 0.34", only: :dev, runtime: false}]
  end

  defp package do
    [
      maintainers: ["Andy Leak"],
      licenses: ["MIT"],
      links: %{"GitHub" => "#{@source_url}/tree/master/installer"},
      files: ~w(lib mix.exs README.md LICENSE.md)
    ]
  end

  defp docs do
    [main: "Mix.Tasks.Composer.New", source_ref: "v#{@version}", extras: ["README.md"]]
  end
end
