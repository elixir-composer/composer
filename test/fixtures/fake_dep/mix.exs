# A package that ships a composer cookbook, for the host app integration test
# (test/integration/host_app_test.exs).
defmodule FakeDep.MixProject do
  use Mix.Project

  def project do
    [app: :fake_dep, version: "0.1.0", deps: [{:composer, path: "../../.."}]]
  end
end
