# A framework that bundles a composer cookbook, with composer as an optional
# dependency, for the composer_new archive's integration test
# (installer/test/integration/composer_new_test.exs) and guides/bundling.md.
defmodule FakeFramework.MixProject do
  use Mix.Project

  def project do
    [
      app: :fake_framework,
      version: "0.1.0",
      deps: [{:composer, path: "../../..", optional: true}]
    ]
  end
end
