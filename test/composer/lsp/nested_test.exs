defmodule Composer.LSP.NestedTest do
  # The language server's features from a buffer in a nested chapter,
  # recipes/ash/ui/tailwind.exs, using relative addresses.
  use ExUnit.Case, async: true

  alias Composer.Lint
  alias Composer.LSP.{Actions, Complete, Convert, Cursor, Definition, Hover, Lookup}
  import Composer.Test.Cookbooks

  @moduletag :tmp_dir

  @tailwind """
  [
    base: [shortdoc: "Tailwind base", steps: ["fake_book:setup:credo"]],
    full: [
      shortdoc: "Everything",
      steps: [
        "./base",
        "../buttons",
        "../../core",
        {:use, "base"}
      ]
    ]
  ]
  """

  setup %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "recipes/ash/ui"))
    File.write!(Path.join(dir, "recipes/ash.exs"), ~s([core: [shortdoc: "Core", steps: []]]\n))

    File.write!(
      Path.join(dir, "recipes/ash/ui.exs"),
      ~s([\n  buttons: [shortdoc: "Buttons", steps: []]\n]\n)
    )

    path = Path.join(dir, "recipes/ash/ui/tailwind.exs")
    File.write!(path, @tailwind)

    cookbooks = discover(dir, [:fake_book])
    snapshot = %{cookbooks: cookbooks, entries: Composer.LSP.entries(cookbooks)}
    %{snapshot: snapshot, path: path, dir: dir}
  end

  defp resolve(%{snapshot: snapshot, path: path}, line, column),
    do: @tailwind |> Cursor.at(path, line, column) |> Lookup.resolve(path, snapshot)

  test "the buffer's context is its nested chapter", %{snapshot: snapshot, path: path} do
    assert Lookup.context(snapshot.cookbooks, path) ==
             %{cookbook: "mine", chapter: "ash/ui/tailwind", cli?: false}
  end

  test "completion of relative, root and qualified addresses", %{snapshot: snapshot, path: path} do
    buffer = Lookup.context(snapshot.cookbooks, path)

    labels = fn prefix ->
      {:steps, prefix, {{1, 1}, {1, 1}}}
      |> Complete.items(snapshot.entries, %{}, buffer)
      |> Enum.map(& &1.label)
    end

    assert labels.("./") == ["./base", "./full"]
    assert labels.("../") == ["../buttons", "../tailwind/"]
    assert labels.("../../") == ["../../core", "../../ui/"]
    assert labels.("/ash/") == ["/ash/core", "/ash/ui/"]
    assert labels.("mine/ash/ui/") == ["mine/ash/ui/buttons", "mine/ash/ui/tailwind/"]
    assert "fake_book:hello" in labels.("fake_book:")
  end

  test "hover and definition through a relative address", context do
    assert {:recipe, %{ref: "mine/ash/ui/buttons"}} = result = resolve(context, 7, 9)

    hover = Hover.render(result, %{project: "host", root: "/host"}, context.snapshot.cookbooks)
    assert hover =~ "**mine/ash/ui/buttons** - Buttons"

    assert {file, {{2, 3}, {2, 11}}} = Definition.target(result, context.snapshot.cookbooks, %{})
    assert Path.basename(file) == "ui.exs"

    assert {:recipe, %{ref: "mine/ash/ui/tailwind/base"}} = resolve(context, 6, 9)
    assert {:recipe, %{ref: "mine/ash/core"}} = resolve(context, 8, 9)
  end

  test "a {:use, ...} entry is a diagnostic with a quick fix", %{snapshot: snapshot, path: path} do
    [use] = Lint.files(snapshot.cookbooks, [path])[path]
    assert use.code == :use_entry
    assert use.fix.text == ~s("./base")

    lsp = Convert.diagnostic(use, :utf16, Convert.lines_for([path]))
    assert [action] = Actions.for_diagnostics("file://" <> path, [lsp])
    assert action.is_preferred
    assert [%{new_text: ~s("./base")}] = action.edit.changes["file://" <> path]
  end
end
