defmodule Composer.Core.Steps.MinimalHomePageTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  describe "home_page" do
    test "replaces an existing home page" do
      igniter =
        test_project(
          files: %{"lib/test_web/controllers/page_html/home.html.heex" => "<div>old</div>\n"}
        )
        |> Igniter.compose_task(Composer.Core.Steps.Phx.MinimalHomePage)

      assert diff(igniter, only: "lib/test_web/controllers/page_html/home.html.heex") =~
               "Layouts.app"
    end

    test "warns instead of creating when the page is missing" do
      igniter = Igniter.compose_task(test_project(), Composer.Core.Steps.Phx.MinimalHomePage)

      assert Enum.any?(igniter.warnings, &(&1 =~ "skipped generating the home page"))
    end

    test "updates the page controller test to match the new page" do
      page_test = """
      defmodule TestWeb.PageControllerTest do
        use TestWeb.ConnCase

        test "GET /", %{conn: conn} do
          conn = get(conn, ~p"/")
          assert html_response(conn, 200) =~ "Peace of mind from prototype to production"
        end
      end
      """

      igniter =
        test_project(
          files: %{
            "lib/test_web/controllers/page_html/home.html.heex" => "<div>old</div>\n",
            "test/test_web/controllers/page_controller_test.exs" => page_test
          }
        )
        |> Igniter.compose_task(Composer.Core.Steps.Phx.MinimalHomePage)

      diff = diff(igniter, only: "test/test_web/controllers/page_controller_test.exs")
      assert diff =~ "assert html_response(conn, 200) =~ \"Home Page\""
      refute diff =~ ~r/\+\s*\|.*Peace of mind/
    end
  end
end
