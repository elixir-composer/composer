defmodule Composer.LSP.ServerTest do
  use Composer.Test.LSPCase, async: false

  alias Composer.LSP.Convert
  alias Composer.Test.LSPFixtures

  @moduletag :tmp_dir
  @moduletag :capture_log

  setup %{tmp_dir: dir} do
    {snapshot, app} = LSPFixtures.workspace(dir)
    opts = Map.to_list(Map.take(snapshot, [:cookbooks, :root, :project, :entries]))
    %{opts: opts, app: app, dir: dir}
  end

  defp open(client, path) do
    cast(client, "textDocument/didOpen", %{
      textDocument: %{
        uri: Convert.path_to_uri(path),
        languageId: "elixir",
        version: 1,
        text: File.read!(path)
      }
    })
  end

  defp save(client, path),
    do: cast(client, "textDocument/didSave", %{textDocument: %{uri: Convert.path_to_uri(path)}})

  defp at(path, line, character),
    do: %{
      textDocument: %{uri: Convert.path_to_uri(path)},
      position: %{line: line, character: character}
    }

  test "initialize negotiates the encoding and names the host", %{opts: opts} do
    {_client, result} = start_server(opts, ["utf-16", "utf-8"])

    assert %{"positionEncoding" => "utf-8", "hoverProvider" => true} = result["capabilities"]
    assert result["serverInfo"]["name"] == "composer-ls"

    assert_receive %{"method" => "window/showMessage", "params" => %{"message" => message}}, 2000
    assert message =~ "composer-ls: host project host_app at "
  end

  test "diagnostics for a saved file and its dependent, cleared once fixed", %{
    opts: opts,
    dir: dir
  } do
    ash = Path.join(dir, "recipes/ash.exs")
    use = Path.join(dir, "recipes/use.exs")
    File.write!(ash, ~s|[\n  base: [shortdoc: "x", steps: ["credoo"]]\n]\n|)
    File.write!(use, ~s|[\n  full: [shortdoc: "x", steps: [{:use, "mine:ash/base"}]]\n]\n|)

    {client, _} = start_server(opts)
    save(client, ash)

    assert [%{"code" => "typo", "source" => "composer", "severity" => 1} = typo] =
             assert_diagnostics(Convert.path_to_uri(ash))

    assert typo["range"] == %{
             "start" => %{"line" => 1, "character" => 32},
             "end" => %{"line" => 1, "character" => 40}
           }

    assert typo["data"]["suggestions"] == ["cb_std:setup/credo", "fake_book:setup/credo"]
    assert [%{"code" => "include_problems"}] = assert_diagnostics(Convert.path_to_uri(use))

    File.write!(ash, ~s|[\n  base: [shortdoc: "x", steps: ["cb_std:setup/credo"]]\n]\n|)
    save(client, ash)

    assert [] = assert_diagnostics(Convert.path_to_uri(ash))
    assert [] = assert_diagnostics(Convert.path_to_uri(use))
  end

  test "a file that is not a recipe group gets nothing", %{opts: opts} do
    {client, _} = start_server(opts)
    open(client, Path.expand("mix.exs"))
    refute_receive %{"method" => "textDocument/publishDiagnostics"}, 500
  end

  test "hover, with the host footer", %{opts: opts, app: app} do
    {client, _} = start_server(opts)
    open(client, app)

    result = call(client, 2, "textDocument/hover", at(app, 7, 8))
    assert result["contents"]["kind"] == "markdown"
    assert result["contents"]["value"] =~ "**fake_book:hello**"
    assert result["contents"]["value"] =~ "host: host_app"
    assert result["range"]["start"] == %{"line" => 7, "character" => 6}
  end

  test "definition of a step: its source", %{opts: opts, app: app} do
    {client, _} = start_server(opts)
    open(client, app)

    result = call(client, 2, "textDocument/definition", at(app, 7, 8))
    assert String.ends_with?(result["uri"], "fake_book/steps/hello.ex")
    assert result["range"]["start"] == %{"line" => 1, "character" => 2}
  end

  test "document links for hex: refs", %{opts: opts, app: app} do
    {client, _} = start_server(opts)
    open(client, app)

    assert [%{"target" => "https://hexdocs.pm/oban"}] =
             call(client, 2, "textDocument/documentLink", %{
               textDocument: %{uri: Convert.path_to_uri(app)}
             })
  end

  test "completion in an unsaved, non-parsing buffer", %{opts: opts, app: app} do
    {client, _} = start_server(opts)
    open(client, app)

    text = ~s|[\n  a: [\n    shortdoc: "x",\n    steps: [\n      "fake_book:he|

    cast(client, "textDocument/didChange", %{
      textDocument: %{uri: Convert.path_to_uri(app), version: 2},
      contentChanges: [%{text: text}]
    })

    result = call(client, 2, "textDocument/completion", at(app, 4, 19))
    item = Enum.find(result["items"], &(&1["label"] == "fake_book:hello"))
    assert item["detail"] == "Writes hello.txt"

    assert item["textEdit"]["range"] == %{
             "start" => %{"line" => 4, "character" => 7},
             "end" => %{"line" => 4, "character" => 19}
           }
  end

  test "a quick fix from a typo's suggestion", %{opts: opts, dir: dir} do
    ash = Path.join(dir, "recipes/ash.exs")
    File.write!(ash, ~s|[\n  base: [shortdoc: "x", steps: ["credoo"]]\n]\n|)
    uri = Convert.path_to_uri(ash)

    {client, _} = start_server(opts)
    open(client, ash)
    [typo] = assert_diagnostics(uri)

    actions =
      call(client, 2, "textDocument/codeAction", %{
        textDocument: %{uri: uri},
        range: typo["range"],
        context: %{diagnostics: [typo]}
      })

    assert [first, _second] = actions
    assert first["title"] == "Replace with `cb_std:setup/credo`"
    assert first["kind"] == "quickfix"

    assert first["edit"]["changes"][uri] == [
             %{"range" => typo["range"], "newText" => ~s("cb_std:setup/credo")}
           ]
  end

  test "composer.reload swaps the cookbooks", %{opts: opts} do
    cookbooks = Keyword.fetch!(opts, :cookbooks)
    {client, _} = start_server(opts ++ [discover: fn -> {:ok, cookbooks} end])

    assert call(client, 2, "workspace/executeCommand", %{
             command: "composer.reload",
             arguments: []
           }) == nil

    assert_receive %{
                     "method" => "window/showMessage",
                     "params" => %{"message" => "composer-ls: reloaded" <> _}
                   },
                   2000
  end
end
