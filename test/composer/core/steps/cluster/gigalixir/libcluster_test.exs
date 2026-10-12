defmodule Composer.Core.Steps.Cluster.Gigalixir.LibclusterTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  test "configures the Kubernetes topology in prod.exs" do
    diff =
      test_project()
      |> Igniter.compose_task(Composer.Core.Steps.Cluster.Gigalixir.Libcluster)
      |> diff(only: "config/prod.exs")

    assert diff =~ "Cluster.Strategy.Kubernetes"
    assert diff =~ "LIBCLUSTER_KUBERNETES_SELECTOR"
  end
end
