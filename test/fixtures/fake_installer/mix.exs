# A package that ships an Igniter installer and no cookbook, installed as
# hex:fake_installer@path:... by the host app integration test
# (test/integration/host_app_test.exs).
defmodule FakeInstaller.MixProject do
  use Mix.Project

  def project do
    [app: :fake_installer, version: "0.1.0", deps: [{:igniter, "~> 0.6"}]]
  end
end
