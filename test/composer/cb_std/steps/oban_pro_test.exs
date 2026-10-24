defmodule Composer.CbStd.Steps.ObanProTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  test "oban_pro configures the Pro engine and services when oban is set up" do
    igniter = Igniter.compose_task(project_with_oban_configured(), Composer.CbStd.Steps.ObanPro)

    mix_diff = diff(igniter, only: "mix.exs")
    assert mix_diff =~ ":oban_pro"
    # Offline fallback requirement (version fetch is disabled in tests)
    assert mix_diff =~ ~s("~> 1.8")

    config_diff = diff(igniter, only: "config/config.exs")
    assert config_diff =~ "engine: Oban.Pro.Engine"
    assert config_diff =~ "cron: {Oban.Pro.Cron, crontab: []}"
    assert config_diff =~ "lifeline: Oban.Pro.Lifeline"
    assert config_diff =~ "pruner: Oban.Pro.Pruner"
    assert config_diff =~ "queues: {Oban.Pro.Queues, sync_mode: :automatic"
    assert config_diff =~ "plugins: [Oban.Pro.Plugins.DynamicPrioritizer]"
    # Oban's installer defaults are superseded, not left alongside Pro's...
    refute config_diff =~ "rescue_after"
    refute config_diff =~ "max_age"
    # ...while what it wrote and Pro doesn't care about survives.
    assert config_diff =~ "repo: Test.Repo"
    refute config_diff =~ "Smart"
    refute config_diff =~ "Dynamic" <> "Queues"

    assert diff(igniter) =~ "Oban.Pro.Migration.up()"
  end

  test "oban_pro warns and skips when oban is missing" do
    igniter = Igniter.compose_task(phx_test_project(), Composer.CbStd.Steps.ObanPro)

    assert Enum.any?(igniter.warnings, &(&1 =~ "Oban setup that isn't here yet"))
    refute diff(igniter, only: "mix.exs") =~ ":oban_pro"
  end

  # A composer adds every package it installs to mix.exs before any step runs,
  # so the dep alone says nothing about whether oban.install has composed yet.
  # Guarding on the dep would let this through and clobber Oban's config.
  test "oban_pro warns and skips when oban is a dep but not yet configured" do
    igniter =
      phx_test_project()
      |> Igniter.Project.Deps.add_dep({:oban, "~> 2.24"})
      |> Igniter.compose_task(Composer.CbStd.Steps.ObanPro)

    assert Enum.any?(igniter.warnings, &(&1 =~ "Oban setup that isn't here yet"))
    refute diff(igniter, only: "mix.exs") =~ ":oban_pro"
  end

  # Stands in for what `oban.install` (Oban 2.24+) leaves behind.
  defp project_with_oban_configured do
    phx_test_project()
    |> Igniter.Project.Deps.add_dep({:oban, "~> 2.24"})
    |> Igniter.Project.Config.configure(
      "config.exs",
      :test,
      [Oban],
      {:code,
       quote(
         do: [
           engine: Oban.Engines.Postgres,
           notifier: Oban.Notifiers.Postgres,
           queues: [default: 10],
           lifeline: [rescue_after: {2, :hours}],
           pruner: [max_age: {1, :day}],
           repo: Test.Repo
         ]
       )}
    )
  end
end
