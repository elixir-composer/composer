defmodule Composer.TemplatesTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  alias Composer.FakeBook.Steps.HelloTemplates
  alias Composer.Templates

  defp ref(path), do: Templates.ref(HelloTemplates, path)

  defp content(igniter, path) do
    igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)
  end

  test "assigns/1 describes the target app" do
    assert Templates.assigns(test_project()) == %{
             app_name: "test",
             app_module: "Test",
             web_module: "TestWeb",
             web_dir: "test_web"
           }
  end

  test ".eex templates are rendered with the assigns and lose the extension" do
    test_project()
    |> Templates.copy_file(ref("greeting.txt.eex"), "out/greeting.txt.eex")
    |> assert_creates("out/greeting.txt", "Hello Test!\n")
  end

  test "caller assigns are merged over the standard ones" do
    test_project()
    |> Templates.copy_file(ref("greeting.txt.eex"), "g.txt", assigns: [app_module: "Pat"])
    |> assert_creates("g.txt", "Hello Pat!\n")
  end

  test "other files, even with <%= %> in them, are copied verbatim" do
    test_project()
    |> Templates.copy_file(ref("raw.heex"), "raw.heex")
    |> assert_creates("raw.heex", "<%= @not_rendered %>\n")
  end

  test "copy_dir/4 copies nested files and dotfiles, expands path variables, skips .gitkeep" do
    igniter = Templates.copy_dir(test_project(), ref("page"), "lib")

    assert content(igniter, "lib/test_web/components/hello.ex") =~
             "defmodule TestWeb.Components.Hello do"

    assert_creates(igniter, "lib/README.md", "# <%= @app_name %>\n")
    assert_creates(igniter, "lib/docs/.keep", "")
    refute Igniter.exists?(igniter, "lib/.gitkeep")
  end

  test "a path variable with no assign raises, naming it and the template" do
    assert_raise ArgumentError, ~r/greeting.txt.eex uses the path variable __nope__/, fn ->
      Templates.copy_file(test_project(), ref("greeting.txt.eex"), "__nope__/g.txt")
    end
  end

  test "an existing file is overwritten by default, or skipped" do
    project = test_project(files: %{"g.txt" => "old\n"})

    assert content(
             Templates.copy_file(project, ref("greeting.txt.eex"), "g.txt"),
             "g.txt"
           ) ==
             "Hello Test!\n"

    project
    |> Templates.copy_file(ref("greeting.txt.eex"), "g.txt", on_exists: :skip)
    |> assert_unchanged("g.txt")
  end

  test "a step's template/1 refers to a file beside the step" do
    assert HelloTemplates.__composer_templates__() == ["greeting.txt.eex"]

    test_project()
    |> Igniter.compose_task(HelloTemplates)
    |> assert_creates("greeting.txt", "Hello Test!\n")
  end

  test "a template/1 path computed at run time is recorded as :dynamic" do
    assert Composer.FakeBook.Steps.DynamicTemplates.__composer_templates__() == [:dynamic]

    test_project()
    |> Igniter.compose_task(Composer.FakeBook.Steps.DynamicTemplates)
    |> assert_creates("one.txt", "one\n")
  end

  test "ref/2 builds a reference into a step's template directory" do
    assert ref("raw.heex") == {"fake_book", "hello_templates", "raw.heex"}
    assert Templates.path(ref("raw.heex")) =~ ~r{fake_book/steps/_hello_templates/raw.heex$}

    assert_raise ArgumentError, ~r/Composer.Templates is not a step module/, fn ->
      Templates.ref(Composer.Templates, "x")
    end
  end

  test "a missing template names the step, the path and where it looked" do
    assert_raise ArgumentError,
                 ~r{"nope.txt" of Composer.FakeBook.Steps.HelloTemplates not found: /.*/steps/_hello_templates/nope.txt does not exist},
                 fn -> Templates.path(ref("nope.txt")) end
  end

  test "a cookbook-level reference, with no step, raises with the new layout" do
    assert_raise ArgumentError, ~r/Cookbook-level templates\/ were removed/, fn ->
      Templates.path({:fake_book, "greeting.txt.eex"})
    end
  end

  @layouts """
  defmodule TestWeb.Layouts do
    def app(assigns) do
      assigns
    end
  end
  """

  test "replace_function/6 swaps in the rendered function" do
    igniter =
      test_project(files: %{"lib/test_web/layouts.ex" => @layouts})
      |> Templates.replace_function(
        TestWeb.Layouts,
        :app,
        1,
        ref("layouts/app_fn.ex.eex"),
        %{class: "px-4"}
      )

    assert content(igniter, "lib/test_web/layouts.ex") =~ ~s(<main class="px-4">)
  end

  test "replace_function/6 warns when the function or module is missing" do
    igniter =
      test_project(files: %{"lib/test_web/layouts.ex" => @layouts})
      |> Templates.replace_function(
        TestWeb.Layouts,
        :app,
        2,
        ref("layouts/app_fn.ex.eex"),
        %{class: "x"}
      )
      |> Templates.replace_function(
        TestWeb.Missing,
        :app,
        1,
        ref("layouts/app_fn.ex.eex"),
        %{class: "x"}
      )

    assert [missing_module, missing_fun] = igniter.warnings
    assert missing_fun =~ "TestWeb.Layouts has no app/2 function"
    assert missing_module =~ "TestWeb.Missing not found"
  end

  test "insert/4 adds content after or before an anchor, or appends, once" do
    project = test_project(files: %{"notes.txt" => "one\ntwo\n"})

    after_one =
      project
      |> Templates.insert("notes.txt", "1.5\n", at: {:after, "one\n"})
      |> Templates.insert("notes.txt", "1.5\n", at: {:after, "one\n"})

    assert content(after_one, "notes.txt") == "one\n1.5\ntwo\n"

    assert project
           |> Templates.insert("notes.txt", "zero\n", at: {:before, "one"})
           |> Templates.insert("notes.txt", "three\n", at: :append)
           |> content("notes.txt") == "zero\none\ntwo\nthree\n"
  end

  test "insert/4 warns loudly when the anchor is missing" do
    igniter =
      test_project(files: %{"notes.txt" => "one\n"})
      |> Templates.insert("notes.txt", "x", at: {:after, "missing"})

    assert [warning] = igniter.warnings
    assert warning =~ ~s(could not find "missing" in notes.txt)
  end

  test "require_present/3 warns about a missing prerequisite" do
    igniter =
      test_project()
      |> Templates.require_present({:dep, :heroicons}, "the sidebar uses heroicons")
      |> Templates.require_present({:file, "mix.exs"}, "it is always there")

    assert igniter.warnings == [
             "the heroicons dependency is missing, but the sidebar uses heroicons. Add it first."
           ]
  end

  test "local has no templates" do
    assert_raise ArgumentError, ~r/local holds recipes only/, fn ->
      Composer.Templates.path({"local", "x", "x.txt"})
    end
  end
end
