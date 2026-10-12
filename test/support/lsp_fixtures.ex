defmodule Composer.Test.LSPFixtures do
  @moduledoc false
  # A local config directory and a workspace snapshot for the language
  # server's tests, against the fake cookbooks.

  @app """
  aliases = [fb: "fake_book"]

  [
    app: [
      shortdoc: "App",
      aliases: aliases,
      steps: [
        "fake_book:hello",
        "fb:ash/postgres",
        "hex:oban",
        "oban",
        {:use, "base"},
        {:use, "fake_book:main/full"},
        "nope:x"
      ]
    ],
    base: [shortdoc: "Base", doc: "The base.", flags: [x: "An x"], steps: ["core:setup/gitignore"]]
  ]
  """

  @doc "The text of `recipes/app.exs`; positions in it are asserted by tests."
  def app_source, do: @app

  @doc "Writes the local config in `dir`; returns the snapshot and the group's path."
  def local(dir) do
    File.mkdir_p!(Path.join(dir, "recipes"))
    path = Path.join(dir, "recipes/app.exs")
    File.write!(path, @app)

    {:ok, cookbooks} =
      Composer.Discovery.cookbooks(apps: [:fake_book, :other_book], local: false)

    snapshot = %{
      cookbooks: cookbooks,
      local_dir: dir,
      root: File.cwd!(),
      project: "host_app",
      encoding: :utf16,
      entries: Composer.LSP.entries(cookbooks),
      buffers: %{}
    }

    {snapshot, path}
  end
end
