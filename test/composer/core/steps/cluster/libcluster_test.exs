defmodule Composer.Core.Steps.LibclusterTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  test "libcluster adds dep, supervision child, and dev topology" do
    igniter = Igniter.compose_task(phx_test_project(), Composer.Core.Steps.Cluster.Libcluster)

    assert diff(igniter, only: "mix.exs") =~ ":libcluster"
    assert diff(igniter, only: "lib/test/application.ex") =~ "Cluster.Supervisor"
    assert diff(igniter, only: "config/dev.exs") =~ "Cluster.Strategy.Gossip"
  end
end
