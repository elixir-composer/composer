defmodule Composer.LSP.ConvertTest do
  use ExUnit.Case, async: true

  alias Composer.Lint.Diagnostic
  alias Composer.LSP.Convert

  @lines %{
    "/r/a.exs" => {~s|[x: [steps: ["é😀", "credoo"]]]|},
    "/r/b.exs" => {"line one"}
  }

  defp line_fun, do: fn path, line -> Convert.line_text(Map.get(@lines, path, {}), line) end

  defp typo do
    :error
    |> Diagnostic.new({:typo, "credoo", "mine:a/x", ["cb_std:setup/credo"]})
    |> Diagnostic.locate("/r/a.exs", {{1, 21}, {1, 29}}, [
      %{file: "/r/b.exs", range: {{1, 6}, {1, 9}}, message: "here"},
      %{file: "/r/c.exs", range: nil, message: "no range"},
      %{file: nil, range: nil, message: "no file"}
    ])
  end

  test "severity, code, source, message and data" do
    lsp = Convert.diagnostic(typo(), :utf16, line_fun())

    assert lsp.severity == 1
    assert lsp.code == "typo"
    assert lsp.source == "composer"
    assert lsp.message =~ "credoo"
    assert lsp.data == %{"code" => "typo", "suggestions" => ["cb_std:setup/credo"]}

    warning = Diagnostic.new(:warning, {:empty_chapter, "/r/a.exs"})
    assert Convert.diagnostic(warning, :utf16, line_fun()).severity == 2
  end

  test "the range is converted on the line's text" do
    # "é😀" before the ref: 2 graphemes, 3 UTF-16 units, 6 bytes, so the
    # 20 graphemes before it are 21 UTF-16 units and 24 bytes.
    assert Convert.diagnostic(typo(), :utf16, line_fun()).range ==
             %{start: %{line: 0, character: 21}, end: %{line: 0, character: 29}}

    assert Convert.diagnostic(typo(), :utf8, line_fun()).range.start.character == 24
  end

  test "related information: a missing range is the file's start, no file is skipped" do
    [here, no_range] = Convert.diagnostic(typo(), :utf16, line_fun()).related_information

    assert here.location.uri == "file:///r/b.exs"
    assert here.location.range.start == %{line: 0, character: 5}
    assert here.message == "here"
    assert no_range.location.range.end == %{line: 0, character: 0}
  end

  test "a diagnostic without a position is at the file's start" do
    d =
      :error |> Diagnostic.new({:empty_chapter, "/r/a.exs"}) |> Diagnostic.locate("/r/a.exs", nil)

    assert Convert.diagnostic(d, :utf16, line_fun()).range.start == %{line: 0, character: 0}
  end

  test "URIs and paths" do
    assert Convert.uri_to_path("file:///home/me/my%20recipes/a.exs") ==
             "/home/me/my recipes/a.exs"

    assert Convert.uri_to_path("file://host/x/y.exs") == "/x/y.exs"
    assert Convert.uri_to_path("untitled:Untitled-1") == nil

    assert Convert.path_to_uri("/home/me/my recipes/a.exs") ==
             "file:///home/me/my%20recipes/a.exs"
  end

  @tag :tmp_dir
  test "lines_for reads each file once, missing ones have no lines", %{tmp_dir: dir} do
    path = Path.join(dir, "a.exs")
    File.write!(path, "one\ntwo\n")
    lines = Convert.lines_for([path, Path.join(dir, "nope.exs")])

    assert lines.(path, 2) == "two"
    assert lines.(Path.join(dir, "nope.exs"), 1) == nil
  end
end
