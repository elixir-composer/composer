defmodule Composer.CbStd.Steps.GigalixirTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  describe "gigalixir" do
    test "creates deployment files without the Oban Pro hook by default" do
      igniter = Igniter.compose_task(phx_test_project(), Composer.CbStd.Steps.Cluster.Gigalixir)

      diff = diff(igniter)
      assert diff =~ "elixir_buildpack.config"
      assert diff =~ "erlang_version="
      assert diff =~ "gigalixir-buildpack-elixir"
      assert diff =~ "rel/overlays/Procfile"
      assert diff =~ "Ecto.Migrator.with_repo"
      refute diff =~ "OBAN_PRO_AUTH_KEY"
    end

    test "includes the Oban Pro hook when oban_pro is a dependency" do
      igniter =
        phx_test_project()
        |> Igniter.Project.Deps.add_dep({:oban_pro, "~> 1.7.0-rc", repo: "oban"})
        |> Igniter.compose_task(Composer.CbStd.Steps.Cluster.Gigalixir)

      assert diff(igniter) =~ "OBAN_PRO_AUTH_KEY"
    end
  end

  describe "gigalixir colocated hooks" do
    @app_js_standalone """
    import {hooks as colocatedHooks} from "phoenix-colocated/test"
    let liveSocket = new LiveSocket("/live", Socket, {
      hooks: {...colocatedHooks},
      params: {_csrf_token: csrfToken}
    })
    """

    @app_js_merged """
    import {hooks as colocatedHooks} from "phoenix-colocated/test"
    let liveSocket = new LiveSocket("/live", Socket, {
      hooks: {...colocatedHooks, ...myHooks},
      params: {_csrf_token: csrfToken}
    })
    """

    # phx_test_project's files option cannot override its default files,
    # so seed app.js content by updating and applying first.
    defp project_with_app_js(content) do
      phx_test_project()
      |> Igniter.update_file("assets/js/app.js", fn source ->
        Rewrite.Source.update(source, :content, content)
      end)
      |> apply_igniter!()
    end

    test "removes import and hooks together when standalone" do
      igniter =
        project_with_app_js(@app_js_standalone)
        |> Igniter.compose_task(Composer.CbStd.Steps.Cluster.Gigalixir)

      diff = diff(igniter, only: "assets/js/app.js")
      assert diff =~ "- |import {hooks as colocatedHooks}"
      assert Enum.any?(igniter.notices, &(&1 =~ "colocated"))
    end

    test "leaves merged hooks untouched with a warning" do
      igniter =
        project_with_app_js(@app_js_merged)
        |> Igniter.compose_task(Composer.CbStd.Steps.Cluster.Gigalixir)

      assert_unchanged(igniter, "assets/js/app.js")
      assert Enum.any?(igniter.warnings, &(&1 =~ "merges colocatedHooks"))
    end

    test "skips removal entirely when bun manages assets" do
      igniter =
        project_with_app_js(@app_js_standalone)
        |> Igniter.Project.Deps.add_dep({:bun, "~> 2.0"})
        |> Igniter.compose_task(Composer.CbStd.Steps.Cluster.Gigalixir)

      assert_unchanged(igniter, "assets/js/app.js")
    end
  end
end
