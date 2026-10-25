defmodule Composer.Test.LSPFixtures do
  @moduledoc false
  # A cookbook of recipes in a tmp dir and a workspace snapshot for the language
  # server's tests, against the fake cookbooks.

  @app """
  aliases = [fb: "fake_book"]

  [
    app: [
      shortdoc: "App",
      aliases: aliases,
      steps: [
        "fake_book:hello",
        "fb:ash:postgres",
        "hex:oban",
        "oban",
        "./base",
        "fake_book/main/full",
        "nope:x"
      ]
    ],
    base: [shortdoc: "Base", doc: "The base.", flags: [x: "An x"], steps: ["cb_std:setup:gitignore"]]
  ]
  """

  @doc "The text of `recipes/app.exs`; positions in it are asserted by tests."
  def app_source, do: @app

  @doc "Writes the cookbook `mine` in `dir`; returns the snapshot and the chapter's path."
  def workspace(dir) do
    File.mkdir_p!(Path.join(dir, "recipes"))
    path = Path.join(dir, "recipes/app.exs")
    File.write!(path, @app)

    cookbooks = Composer.Test.Cookbooks.discover(dir, [:fake_book, :other_book])

    snapshot = %{
      cookbooks: cookbooks,
      root: File.cwd!(),
      project: "host_app",
      encoding: :utf16,
      entries: Composer.LSP.entries(cookbooks),
      buffers: %{}
    }

    {snapshot, path}
  end
end
